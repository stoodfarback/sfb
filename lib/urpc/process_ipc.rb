# frozen_string_literal: true

module Urpc
  module ProcessIpc
    READY_BYTE = "\0".b.freeze
    LENGTH_BYTES = 4

    def self.write_ready(io)
      write_all(io, READY_BYTE)
    end

    def self.write_message(io, bytes)
      write_all(io, [bytes.bytesize].pack("N") + bytes)
    end

    def self.read_message(io)
      length_bytes = read_exact(io, LENGTH_BYTES, eof_ok: true)
      return if !length_bytes

      length = length_bytes.unpack1("N")
      if length < Urpc::SubmitFrame::HEADER_BYTES || length > Urpc::SubmitFrame::ATOMIC_WRITE_BYTES
        raise("invalid urpc process message length: #{length}")
      end
      read_exact(io, length)
    end

    def self.read_exact(io, bytesize, eof_ok: false)
      bytes = String.new(encoding: Encoding::BINARY)
      while bytes.bytesize < bytesize
        begin
          bytes << io.readpartial(bytesize - bytes.bytesize)
        rescue EOFError
          return if eof_ok && bytes.empty?
          raise
        end
      end
      bytes
    end

    def self.write_all(io, bytes)
      offset = 0
      while offset < bytes.bytesize
        offset += io.write(bytes.byteslice(offset, bytes.bytesize - offset))
      end
      bytes.bytesize
    end
  end
end
