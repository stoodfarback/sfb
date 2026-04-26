# frozen_string_literal: true

module Urpc
  class Backend
    attr_accessor(:key, :sock, :unpacker, :broker, :worker_thread)

    def initialize(key:, sock:, unpacker:, broker:)
      self.key = key
      self.sock = sock
      self.unpacker = unpacker
      self.broker = broker
    end

    def start
      self.worker_thread = Thread.new { worker_loop }
      worker_thread.report_on_exception = false
    end

    def worker_loop
      loop do
        call = broker.queue_for(key).pop
        break if !call
        process(call)
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET, MessagePack::UnpackError => e
      warn("urpc broker worker: backend died: #{e.class} #{e.message}")
    ensure
      @current_reply_io&.close rescue nil
      @current_reply_io = nil
      sock.close rescue nil
      broker.unregister_backend(self)
    end

    def process(call)
      @current_reply_io = nil

      if !call.cast?
        @current_reply_io = Util.open_reply_writer(call.reply_path)
        if !@current_reply_io
          broker.remove_active(call.id)
          unlink_quiet(call.reply_path)
          return
        end
      end

      begin
        broker.in_flight_inc(key)
        sock.write(MessagePack.pack(call.to_backend_request))

        loop do
          frame = unpacker.read
          raise(MessagePack::UnpackError, "malformed backend frame") if !Frames.valid_response_frame?(frame)
          type = frame[0]
          broker.broadcast_monitor_response(call, frame)
          if @current_reply_io
            begin
              @current_reply_io.write(MessagePack.pack(frame))
            rescue Errno::EPIPE
              @current_reply_io.close rescue nil
              @current_reply_io = nil
            end
          end
          if call.cast? && type == :error
            warn("urpc broker: cast to #{key} returned error: #{frame.inspect}")
          end
          break if Frames::TERMINAL_TYPES.include?(type)
        end
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, MessagePack::UnpackError => e
        synthesize_backend_died(call, e) if @current_reply_io
        raise
      ensure
        broker.in_flight_dec(key)
        broker.remove_active(call.id)
        @current_reply_io&.close rescue nil
        @current_reply_io = nil
        unlink_quiet(call.reply_path) if !call.cast?
      end
    end

    def synthesize_backend_died(call, error)
      frame = Frames.error_frame(RemoteException.new("backend connection lost: #{error.class} #{error.message}"))
      broker.broadcast_monitor_response(call, frame)
      @current_reply_io.write(MessagePack.pack(frame))
    rescue Errno::EPIPE
      nil
    ensure
      @current_reply_io.close rescue nil
      @current_reply_io = nil
    end

    def unlink_quiet(path)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end
  end
end
