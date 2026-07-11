# frozen_string_literal: true

module Urpc
  class InputStream
    attr_accessor(:writer)

    def initialize(writer)
      self.writer = writer
    end

    def self.open(paths, id:)
      path = paths.input_fifo(id)
      io = nil

      begin
        io = Urpc::Fifo.open(path, File::WRONLY | File::NONBLOCK)
        File.unlink(path)

        stream = new(Urpc::FrameWriter.new(io))
        stream.send_ready!
        stream
      rescue Errno::ENOENT, Errno::ENXIO, Errno::EPIPE
        if io && !io.closed?
          io.close
        end
        raise(Urpc::ServerDisconnected, "urpc server disconnected before input attachment")
      end
    end

    def send_ready!
      writer.write_frame(:ready)
      nil
    end

    def send_sync(value)
      write_input_frame(:sync, value)
    end

    def send_async(value)
      write_input_frame(:async, value)
    end

    def write_input_frame(type, value)
      if !open?
        raise(IOError, "urpc input stream is closed")
      end

      writer.write_frame(type, value)
      nil
    end

    def close
      writer.close
    end

    def closed?
      writer.closed?
    end

    def open?
      !closed?
    end
  end
end
