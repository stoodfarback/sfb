# frozen_string_literal: true

module Urpc
  class EventStream
    READ_CHUNK = 65_536

    attr_accessor(:client, :call, :reply_io, :unpacker, :pending, :had_data, :is_finished, :result_value, :error_value,
      :initial_response_deadline, :inbox_io, :inbox_path, :inbox_write_lock)

    def initialize(client:, method_name:, args:, kargs:, bidirectional:)
      self.client = client
      self.unpacker = MessagePack::DefaultFactory.unpacker
      self.pending = []
      self.is_finished = false
      self.had_data = false
      self.inbox_write_lock = Mutex.new
      self.call = Call.new(
        id: SecureRandom.hex(16),
        rpc_key: client.rpc_key,
        name: method_name,
        args: args,
        kargs: kargs,
        cast: false,
        wait_for_server: client.wait_for_server,
        bidirectional: bidirectional,
      )

      begin
        File.mkfifo(call.reply_path)
        self.reply_io = File.open(call.reply_path, File::RDONLY | File::NONBLOCK)
        Util.clear_nonblock(reply_io)
        client.submit_call(call)
        self.initial_response_deadline = client.initial_response_deadline
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
      loop do
        event = await_event
        next if handle_event(event) == :internal
        return(event)
      end
    end

    def each_event
      return if is_finished
      loop do
        yield(next_event)
        break if is_finished
      end
    end

    def result
      if !is_finished
        each_event {}
      end
      raise(error_value) if error_value
      result_value
    end

    def finished? = is_finished
    def inbox_open? = !!inbox_io && !inbox_io.closed?

    def close
      self.is_finished = true
      cleanup
    end

    def await_inbox
      return true if inbox_open?
      return false if is_finished

      loop do
        event = await_event
        if handle_event(event) == :internal
          return true if inbox_open?
          next
        end

        return false if is_finished
        pending.unshift(event)
        return false
      end
    end

    def send_sync(value)
      write_inbox_frame(:sync, value)
    end

    def send_async(value)
      write_inbox_frame(:async, value)
    end

    def close_inbox
      inbox_io&.close rescue nil
      self.inbox_io = nil
      self.inbox_path = nil
      nil
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

    def current_wait_timeout
      return client.io_select_timeout if had_data
      return client.io_select_timeout if !initial_response_deadline
      remaining = initial_response_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      remaining.positive? ? remaining : 0
    end

    def handle_event(event)
      case event.type
      when :inbox
        handle_inbox(event.data)
        :internal
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

    def handle_inbox(path)
      raise(ArgumentError, "invalid inbox path") if !path.is_a?(String) || path.empty?
      close_inbox
      self.inbox_path = path
      self.inbox_io = open_inbox_writer(path)
      write_inbox_frame(:ready, nil)
      nil
    end

    def open_inbox_writer(path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + inbox_open_timeout
      loop do
        begin
          io = IO.open(IO.sysopen(path, File::WRONLY | File::NONBLOCK))
          if !io.stat.pipe?
            io.close rescue nil
            raise(ArgumentError, "inbox path is not a FIFO: #{path}")
          end
          Util.clear_nonblock(io)
          return io
        rescue Errno::ENOENT, Errno::ENXIO
          raise(TimeoutException, "inbox open timed out") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep(0.01)
        end
      end
    end

    def inbox_open_timeout
      client.io_select_timeout || BidirectionalHandler::INBOX_OPEN_TIMEOUT
    end

    def write_inbox_frame(type, value)
      raise("inbox is not open") if !inbox_open?
      inbox_write_lock.synchronize do
        inbox_io.write(Frames.pack(type, value))
        inbox_io.flush
      end
      nil
    end

    def await_event
      loop do
        return consume_pending if has_pending?
        raise(TimeoutException) if !reply_io.wait_readable(current_wait_timeout)
        fill_buffer_once
      end
    end

    def cleanup
      close_inbox
      reply_io&.close rescue nil
      self.reply_io = nil
      File.unlink(call.request_path) rescue nil
      File.unlink(call.reply_path) rescue nil
    end
  end
end
