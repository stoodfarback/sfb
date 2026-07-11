# frozen_string_literal: true

module Urpc
  class FrameReader
    CHUNK_BYTES = 16 * 1024

    attr_accessor(:io, :parser, :deadline, :eof)

    def initialize(io, timeout:)
      self.io = io
      self.parser = Urpc::StreamFrame::Parser.new
      self.deadline = timeout && timeout != 0 ? Urpc::Deadline.after(timeout) : nil
      self.eof = false
    end

    def next_frame
      loop do
        frame = parser.read_frame
        return frame if frame
        return clean_eof if eof

        wait_for_bytes!
        read_available_bytes!
      end
    end

    def wait_for_bytes!
      readable = io.wait_readable(remaining_timeout)
      if !readable
        timeout!
      end
    end

    def read_available_bytes!
      bytes = io.read_nonblock(CHUNK_BYTES, exception: false)

      if bytes == :wait_readable
        return
      end
      if bytes.nil?
        self.eof = true
        return
      end

      parser.feed(bytes)
    end

    def clean_eof
      if parser.partial?
        raise(EOFError, "urpc stream ended mid-frame")
      end

      nil
    end

    def remaining_timeout
      return if !deadline

      remaining = deadline.remaining
      if remaining <= 0
        timeout!
      end
      remaining
    end

    def timeout!
      close
      raise(Urpc::TimeoutException, "urpc call timed out")
    end

    def close
      if !io.closed?
        io.close
      end
    end

    def closed?
      io.closed?
    end
  end
end
