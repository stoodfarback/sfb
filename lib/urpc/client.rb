# frozen_string_literal: true

module Urpc
  class Client
    attr_accessor(:rpc_key, :timeout, :wait_for_server)

    def initialize(rpc_key, timeout: 0, wait_for_server: false)
      self.rpc_key = rpc_key
      self.timeout = timeout
      self.wait_for_server = wait_for_server
    end

    def call(method_name, *, **, &block)
      raise(ArgumentError, "block not allowed over RPC") if block
      s = stream(method_name, *, **)
      begin
        s.result
      ensure
        s.close
      end
    end

    def stream(method_name, *args, **kargs)
      raise(ArgumentError, "block not allowed over RPC") if block_given?
      preflight!
      EventStream.new(client: self, method_name: method_name, args: args, kargs: kargs, bidirectional: false)
    end

    def bidirectional_stream(method_name, *args, **kargs)
      raise(ArgumentError, "block not allowed over RPC") if block_given?
      preflight!
      EventStream.new(client: self, method_name: method_name, args: args, kargs: kargs, bidirectional: true)
    end

    def cast(method_name, *args, **kargs)
      raise(ArgumentError, "block not allowed over RPC") if block_given?
      preflight!
      call_obj = Call.new(
        id: SecureRandom.hex(16),
        rpc_key: rpc_key,
        name: method_name,
        args: args,
        kargs: kargs,
        cast: true,
        wait_for_server: wait_for_server,
      )
      submit_call(call_obj)
      nil
    end

    def method_missing(...)
      call(...)
    end

    def respond_to_missing?(method_name, include_private = false)
      call(:respond_to?, method_name, include_private)
    end

    def next_event(*streams)
      active = streams.reject(&:finished?)
      return if active.empty?
      loop do
        ready_stream = active.find(&:has_pending?)
        if ready_stream
          event = ready_stream.consume_pending
          next if ready_stream.handle_event(event) == :internal
          return [ready_stream, event]
        end
        ios = active.map(&:reply_io)
        ready, = IO.select(ios, nil, nil, select_timeout_for_streams(active))
        raise(TimeoutException) if !ready
        ready.each do |io|
          s = active.find {|x| x.reply_io == io }
          next if !s
          s.fill_buffer_once
        end
      end
    end

    def each_event(*streams, &block)
      active = streams.reject(&:finished?)
      return if active.empty?
      loop do
        pair = next_event(*active)
        return if !pair
        block.call(*pair)
        active = active.reject(&:finished?)
        return if active.empty?
      end
    end

    def preflight!
      raise(BrokerUnavailable, "broker root missing: #{Urpc.root}") if !File.directory?(Urpc.root)
      raise(BrokerUnavailable, "broker socket missing: #{Urpc.broker_sock}") if !File.socket?(Urpc.broker_sock)
      raise(BrokerUnavailable, "in.fifo missing: #{Urpc.in_fifo}") if !File.pipe?(Urpc.in_fifo)
    end

    SUBMIT_DEADLINE = 5.0

    def submit_call(call)
      body = call.body_payload
      envelope = build_envelope(call, inline: false)
      candidate_size = envelope.bytesize + 2 + body.bytesize
      inline = candidate_size <= SubmitFrame::INLINE_FRAME_MAX

      if inline
        frame = build_envelope(call, inline: true) + [body.bytesize].pack("n") + body
        write_frame(frame)
      else
        File.open(call.request_path, File::WRONLY | File::CREAT | File::EXCL) do |io|
          io.write(body)
        end
        begin
          write_frame(envelope)
        rescue
          File.unlink(call.request_path) rescue nil
          raise
        end
      end
    end

    def build_envelope(call, inline:)
      flags = 0
      flags |= SubmitFrame::SUBMIT_FLAG_INLINE if inline
      flags |= SubmitFrame::SUBMIT_FLAG_CAST if call.cast?
      flags |= SubmitFrame::SUBMIT_FLAG_BIDIRECTIONAL if call.bidirectional?
      SubmitFrame.encode_envelope(
        id_bin: [call.id].pack("H*"),
        flags: flags,
        wait_for_server: call.wait_for_server,
        rpc_key: call.rpc_key,
        method_name: call.name,
      )
    end

    def write_frame(frame)
      File.open(Urpc.in_fifo, File::WRONLY | File::NONBLOCK) do |io|
        raise(BrokerUnavailable, "submit to #{Urpc.in_fifo} timed out") if !io.wait_writable(SUBMIT_DEADLINE)
        written = io.write_nonblock(frame)
        raise(BrokerUnavailable, "short submit write to #{Urpc.in_fifo}: wrote #{written} of #{frame.bytesize}") if written != frame.bytesize
      end
    rescue Errno::ENXIO, Errno::ENOENT, Errno::EPIPE
      raise(BrokerUnavailable, "submit to #{Urpc.in_fifo} failed")
    rescue IO::WaitWritable, Errno::EAGAIN
      raise(BrokerUnavailable, "submit to #{Urpc.in_fifo} timed out during write")
    end

    def io_select_timeout
      timeout == 0 ? nil : timeout
    end

    def wait_for_server_seconds
      Call.wait_for_server_seconds(wait_for_server)
    end

    def initial_response_timeout
      return if timeout == 0
      seconds = wait_for_server_seconds
      seconds ? timeout + seconds : timeout
    end

    def initial_response_deadline
      return if !wait_for_server_seconds
      initial_timeout = initial_response_timeout
      return if !initial_timeout
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + initial_timeout
    end

    def select_timeout_for_streams(streams)
      timeouts = streams.map(&:current_wait_timeout).compact
      timeouts.empty? ? nil : timeouts.min
    end

    def hydrate_error(data)
      klass_s = data[:exception] || "RuntimeError"
      message = data[:message] || ""
      backtrace = data[:backtrace] || []
      e_obj = nil
      if klass_s == RemoteException.to_s
        e_obj = RemoteException.new(message, backtrace)
      elsif Object.const_defined?(klass_s)
        klass = Object.const_get(klass_s)
        e_obj = klass.new(message) rescue nil
      end
      e_obj ||= RemoteException.new("#{klass_s} #{message}", backtrace)
      e_obj.set_backtrace(backtrace + ["<rpc>"] + caller)
      e_obj
    end
  end
end
