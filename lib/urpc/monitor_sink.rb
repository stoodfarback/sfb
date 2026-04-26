# frozen_string_literal: true

module Urpc
  class MonitorSink
    attr_accessor(:sink, :broker, :call)

    def initialize(sink:, broker:, call:)
      self.sink = sink
      self.broker = broker
      self.call = call
    end

    def write_response(type, value)
      broker.broadcast_monitor_response(call, Frames.frame(type, value))
      sink.write_response(type, value)
    end

    def write_error(exception)
      broker.broadcast_monitor_response(call, Frames.error_frame(exception))
      sink.write_error(exception)
    end
  end
end
