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
      sock.close rescue nil
      broker.unregister_backend(self)
    end

    def process(call)
      if !call.ensure_reply_open
        broker.abandon_call(call)
        return
      end

      broker.in_flight_inc(key)
      dispatched = false
      call_reclaimed = false
      begin
        sock.write(MessagePack.pack(call.to_backend_request))
        dispatched = true

        loop do
          frame = unpacker.read
          raise(MessagePack::UnpackError, "malformed backend frame") if !Frames.valid_response_frame?(frame)
          type = frame[0]
          broker.broadcast_monitor_response(call, frame)
          call.write_reply_frame(frame)
          if call.cast? && type == :error
            warn("urpc broker: cast to #{key} returned error: #{frame.inspect}")
          end
          break if Frames::TERMINAL_TYPES.include?(type)
        end
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, MessagePack::UnpackError => e
        if dispatched
          synthesize_backend_died(call, e) if call.reply_open?
        else
          broker.backend_dispatch_failed(self, call)
          call_reclaimed = true
        end
        raise
      ensure
        broker.in_flight_dec(key)
        if !call_reclaimed
          broker.finish_call(call)
        end
      end
    end

    def synthesize_backend_died(call, error)
      frame = Frames.error_frame(RemoteException.new("backend connection lost: #{error.class} #{error.message}"))
      broker.broadcast_monitor_response(call, frame)
      call.write_reply_frame(frame)
    ensure
      call.close_reply_io
    end
  end
end
