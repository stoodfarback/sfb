# frozen_string_literal: true

module Urpc
  class SubmitReader
    CHUNK_BYTES = 16 * 1024

    Submit = Data.define(:header, :payload, :request) do
      def id = header.id
      def inline? = header.inline?
      def file_backed? = header.file_backed?
      def cast? = header.cast?
      def bidirectional? = header.bidirectional?
      def name = request.name
      def args = request.args
      def kargs = request.kargs
    end

    Accepted = Data.define(:bytes) do
      def header
        Urpc::SubmitFrame.unpack_header(bytes.byteslice(0, Urpc::SubmitFrame::HEADER_BYTES))
      end

      def id = header.id
      def inline? = header.inline?
      def file_backed? = header.file_backed?
      def cast? = header.cast?
      def bidirectional? = header.bidirectional?

      def hydrate(paths)
        accepted_header = header
        payload = if accepted_header.inline?
          bytes.byteslice(Urpc::SubmitFrame::HEADER_BYTES, accepted_header.payload_len)
        else
          read_file_payload(paths, accepted_header.id)
        end

        Submit.new(
          header: accepted_header,
          payload:,
          request: Urpc::SubmitFrame.unpack_request(payload),
        )
      end

      def read_file_payload(paths, id)
        path = paths.call_file(id)
        payload = File.binread(path)
        File.unlink(path)
        payload
      end
    end

    attr_accessor(:paths, :io, :buffer)

    def initialize(paths, io)
      self.paths = paths
      self.io = io
      self.buffer = String.new(encoding: Encoding::BINARY)
    end

    def next_submit
      next_accepted.hydrate(paths)
    end

    def next_accepted
      header_bytes = read_bytes(Urpc::SubmitFrame::HEADER_BYTES)
      header = Urpc::SubmitFrame.unpack_header(header_bytes)
      inline_payload = header.inline? ? read_bytes(header.payload_len) : "".b
      Accepted.new(bytes: (header_bytes + inline_payload).freeze)
    end

    def read_bytes(bytesize)
      fill_buffer_until(bytesize)
      buffer.slice!(0, bytesize)
    end

    def fill_buffer_until(bytesize)
      while buffer.bytesize < bytesize
        read_available_bytes!
      end
    end

    def read_available_bytes!
      io.wait_readable

      bytes = io.read_nonblock(CHUNK_BYTES, exception: false)
      if bytes == :wait_readable
        return
      end
      if bytes.nil?
        raise(EOFError, "submit fifo ended")
      end

      buffer << bytes
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
