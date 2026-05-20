# frozen_string_literal: true

module Urpc
  class ResponseStream
    attr_accessor(:sink, :is_finished, :write_lock)

    def initialize(sink:)
      self.sink = sink
      self.is_finished = false
      self.write_lock = Mutex.new
    end

    def data(value)
      write_lock.synchronize do
        raise("already finished, can't send more") if is_finished
        sink.write_response(:data, value)
      end
      nil
    end

    def return(value)
      write_lock.synchronize do
        raise("double-finish") if is_finished
        sink.write_response(:return, value)
        self.is_finished = true
      end
      nil
    end

    def error(exception)
      write_lock.synchronize do
        raise("double-finish") if is_finished
        sink.write_error(exception)
        self.is_finished = true
      end
      nil
    end

    def write_response(type, value)
      write_lock.synchronize { sink.write_response(type, value) }
      nil
    end

    def write_error(exception)
      write_lock.synchronize { sink.write_error(exception) }
      nil
    end

    def write_control(type, value)
      write_lock.synchronize { sink.write_control(type, value) }
      nil
    end

    module Sinks
      class Socket
        attr_accessor(:io)

        def initialize(io)
          self.io = io
        end

        def write_response(type, value)
          io.write(Frames.pack(type, value))
          io.flush
        end

        def write_error(exception)
          io.write(Frames.pack_error(exception))
          io.flush
        end

        def write_control(type, value)
          io.write(Frames.pack(type, value))
          io.flush
        end
      end

      class Null
        def write_response(_type, _value); end
        def write_error(_exception); end
      end
    end
  end
end
