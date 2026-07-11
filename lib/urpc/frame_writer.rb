# frozen_string_literal: true

module Urpc
  class FrameWriter
    attr_accessor(:io, :write_mutex)

    def initialize(io)
      self.io = io
      self.write_mutex = Mutex.new
    end

    def write_frame(type, value = Urpc::StreamFrame::NO_VALUE)
      write(Urpc::StreamFrame.pack(type, value))
    end

    def write(bytes)
      write_mutex.synchronize do
        bytesize = bytes.bytesize
        offset = 0
        pending = bytes

        while offset < bytesize
          written = io.write_nonblock(pending, exception: false)

          if written == :wait_writable
            io.wait_writable
          elsif written == 0
            raise("zero-length urpc frame write")
          else
            offset += written
            if offset < bytesize
              pending = bytes.byteslice(offset, bytesize - offset)
            end
          end
        end

        bytesize
      end
    end

    def close
      write_mutex.synchronize do
        if !io.closed?
          io.close
        end
      end
    end

    def closed?
      write_mutex.synchronize { io.closed? }
    end
  end
end
