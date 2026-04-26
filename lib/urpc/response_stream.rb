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
      raise("already finished, can't send more") if is_finished
      write_response(:data, value)
    end

    def return(value)
      raise("double-finish") if is_finished
      write_response(:return, value)
      self.is_finished = true
      nil
    end

    def error(exception)
      raise("double-finish") if is_finished
      write_error(exception)
      self.is_finished = true
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

    module Sinks
      class Socket
        attr_accessor(:io)

        def initialize(io)
          self.io = io
        end

        def write_response(type, value)
          io.write(Frames.pack(type, value))
        end

        def write_error(exception)
          io.write(Frames.pack_error(exception))
        end
      end

      class Fifo
        attr_accessor(:io)

        def initialize(io)
          self.io = io
        end

        def write_response(type, value)
          io.write(Frames.pack(type, value))
        rescue Errno::EPIPE
          nil
        end

        def write_error(exception)
          io.write(Frames.pack_error(exception))
        rescue Errno::EPIPE
          nil
        end
      end

      class Null
        def write_response(_type, _value); end
        def write_error(_exception); end
      end
    end
  end
end
