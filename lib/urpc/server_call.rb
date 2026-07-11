# frozen_string_literal: true

module Urpc
  class ServerCall
    READY_TIMEOUT = 1.0

    attr_accessor(:paths, :submit, :output, :input_reader)

    def initialize(paths, submit)
      self.paths = paths
      self.submit = submit
      self.output = nil
      self.input_reader = nil
    end

    def self.open(paths, submit)
      call = new(paths, submit)
      if submit.cast?
        return call
      end

      begin
        call.open_output!
        if submit.bidirectional?
          call.open_input!
          call.output.write_frame(:input_ready)
          if !call.read_ready!
            call.drop!
            return
          end
        end

        call
      rescue Errno::ENOENT, Errno::ENXIO, Errno::EPIPE, Urpc::TimeoutException, EOFError
        call.drop!
        nil
      rescue
        call.drop!
        raise
      end
    end

    def id
      submit.id
    end

    def cast?
      submit.cast?
    end

    def bidirectional?
      submit.bidirectional?
    end

    def open_output!
      path = paths.output_fifo(id)
      io = Urpc::Fifo.open(path, File::WRONLY | File::NONBLOCK)
      File.unlink(path)
      self.output = Urpc::FrameWriter.new(io)
    end

    def open_input!
      path = paths.input_fifo(id)
      io = Urpc::Fifo.open(path, File::RDONLY | File::NONBLOCK)
      self.input_reader = Urpc::FrameReader.new(io, timeout: READY_TIMEOUT)
    end

    def read_ready!
      frame = input_reader.next_frame
      return false if !frame

      if frame.type != :ready
        raise("expected READY, got #{frame.type}")
      end

      input_reader.deadline = nil
      true
    end

    def drop!
      close
      cleanup_paths!
    end

    def cleanup_paths!
      [
        paths.call_file(id),
        paths.output_fifo(id),
        paths.input_fifo(id),
      ].each do |path|
        begin
          File.unlink(path)
        rescue Errno::ENOENT
        end
      end
    end

    def close
      if output && !output.closed?
        output.close
      end
      if input_reader && !input_reader.closed?
        input_reader.close
      end
    end

    def closed?
      output_closed = output.nil? || output.closed?
      input_closed = input_reader.nil? || input_reader.closed?
      output_closed && input_closed
    end
  end
end
