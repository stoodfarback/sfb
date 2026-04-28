# frozen_string_literal: true

module Urpc
  class EventStream
    READ_CHUNK = 65_536

    attr_accessor(:client, :call, :reply_io, :unpacker, :pending, :had_data, :is_finished, :result_value, :error_value)

    def initialize(client:, method_name:, args:, kargs:)
      self.client = client
      self.unpacker = MessagePack::DefaultFactory.unpacker
      self.pending = []
      self.is_finished = false
      self.had_data = false
      self.call = Call.new(
        id: SecureRandom.hex(16),
        rpc_key: client.rpc_key,
        name: method_name,
        args: args,
        kargs: kargs,
        cast: false,
        wait_for_server: client.wait_for_server,
      )

      begin
        File.mkfifo(call.reply_path)
        self.reply_io = File.open(call.reply_path, File::RDONLY | File::NONBLOCK)
        Util.clear_nonblock(reply_io)
        call.write_request_file!
        client.submit(call.id)
      rescue
        cleanup
        raise
      end
    end

    def id
      call.id
    end

    def next_event
      raise("stream is finished") if is_finished
      event = await_event
      handle_event(event)
      event
    end

    def each_event
      return if is_finished
      loop do
        yield(next_event)
        break if is_finished
      end
    end

    def result
      each_event {} if !is_finished
      raise(error_value) if error_value
      result_value
    end

    def finished? = is_finished

    def close
      self.is_finished = true
      cleanup
    end

    def has_pending?
      !pending.empty?
    end

    def consume_pending
      pending.shift
    end

    def fill_buffer_once
      chunk = reply_io.read_nonblock(READ_CHUNK, exception: false)
      case chunk
      when :wait_readable
        return :wait_readable
      when nil
        if had_data
          raise("urpc transport error: EOF before terminal frame")
        else
          raise(BrokerUnavailable, "reply fifo closed without writer")
        end
      end
      self.had_data = true
      unpacker.feed(chunk)
      unpacker.each do |frame|
        pending << Event.new(raw_frame: frame)
      end
      :ok
    end

    def handle_event(event)
      case event.type
      when :return
        self.result_value = event.data
        self.is_finished = true
        cleanup
      when :error
        self.error_value = client.hydrate_error(event.data || {})
        self.is_finished = true
        cleanup
      end
    end

    def await_event
      loop do
        return consume_pending if has_pending?
        raise(TimeoutException) if !reply_io.wait_readable(client.io_select_timeout)
        fill_buffer_once
      end
    end

    def cleanup
      reply_io&.close rescue nil
      self.reply_io = nil
      File.unlink(call.request_path) rescue nil
      File.unlink(call.reply_path) rescue nil
    end
  end
end
