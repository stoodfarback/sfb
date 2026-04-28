# frozen_string_literal: true

module Urpc
  class InternalBackend
    attr_accessor(:key, :broker, :handler, :worker_thread)

    def initialize(key:, broker:, handler:)
      self.key = key
      self.broker = broker
      self.handler = handler
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
    rescue => e
      warn("urpc broker internal backend: #{e.class} #{e.message}")
    ensure
      broker.unregister_internal_backend(self)
    end

    def process(call)
      if !call.ensure_reply_open
        broker.abandon_call(call)
        return
      end

      sink = call.cast? ? ResponseStream::Sinks::Null.new : ResponseStream::Sinks::Fifo.new(call.reply_io)
      sink = MonitorSink.new(sink: sink, broker: broker, call: call)
      stream = ResponseStream.new(sink: sink)
      begin
        broker.in_flight_inc(key)
        req = Req.new(args: call.args, kargs: call.kargs, stream: stream)
        handler.send(call.name, req)
        if !stream.is_finished
          stream.error("stream not finished but method returned")
        end
      rescue => e
        if !call.cast? && !stream.is_finished
          begin
            stream.error(e)
          rescue
            nil
          end
        end
      ensure
        broker.in_flight_dec(key)
        broker.finish_call(call)
      end
    end
  end
end
