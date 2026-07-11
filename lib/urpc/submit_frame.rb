# frozen_string_literal: true

module Urpc
  module SubmitFrame
    INLINE = 0x01
    CAST = 0x02
    BIDIRECTIONAL = 0x04
    KNOWN_FLAGS = INLINE | CAST | BIDIRECTIONAL

    HEADER_BYTES = 11
    PAYLOAD_LEN_FIELD_MAX = (2 ** 16) - 1
    ATOMIC_WRITE_BYTES = 4096 - 20
    INLINE_PAYLOAD_LEN_MAX = ATOMIC_WRITE_BYTES - HEADER_BYTES

    Request = Data.define(:name, :args, :kargs)
    Header = Data.define(:flags, :id, :payload_len) do
      def inline? = (flags & INLINE) != 0
      def cast? = (flags & CAST) != 0
      def bidirectional? = (flags & BIDIRECTIONAL) != 0
      def file_backed? = !inline?
    end

    Submission = Data.define(:id, :flags, :payload) do
      def self.build(method_name, args, kargs, cast:, bidirectional:)
        flags = 0
        if cast
          flags |= SubmitFrame::CAST
        end
        if bidirectional
          flags |= SubmitFrame::BIDIRECTIONAL
        end
        SubmitFrame.validate_flags!(flags)

        new(
          id: Urpc::Id.generate,
          flags:,
          payload: SubmitFrame.pack_request(method_name, args, kargs).freeze,
        )
      end

      def cast? = (flags & SubmitFrame::CAST) != 0
      def bidirectional? = (flags & SubmitFrame::BIDIRECTIONAL) != 0
      def inline? = payload.bytesize <= SubmitFrame::INLINE_PAYLOAD_LEN_MAX
      def output? = !cast?
      def input? = bidirectional?

      def frame
        if inline?
          SubmitFrame.pack_inline(id:, flags:, payload:)
        else
          SubmitFrame.pack_file_backed(id:, flags:)
        end
      end

      def file_payload
        return if inline?
        payload
      end
    end

    def self.pack_request(method_name, args, kargs)
      method_name_string = method_name.to_s
      if method_name_string.empty?
        raise(ArgumentError, "invalid urpc method name: #{method_name.inspect}")
      end

      MessagePack.pack([method_name_string, args, kargs])
    end

    def self.unpack_request(payload)
      data = MessagePack.unpack(payload)
      if !data.is_a?(Array) || data.size != 3
        raise(ArgumentError, "invalid urpc request payload")
      end

      method_name, args, kargs = data
      if !method_name.is_a?(String) || method_name.empty? || !args.is_a?(Array) || !kargs.is_a?(Hash)
        raise(ArgumentError, "invalid urpc request payload")
      end

      Request.new(name: method_name.to_sym, args:, kargs:)
    end

    def self.pack_inline(id:, flags:, payload:)
      if payload.bytesize > INLINE_PAYLOAD_LEN_MAX
        raise(ArgumentError, "inline payload too large: #{payload.bytesize}")
      end

      pack_header(id:, flags: flags | INLINE, payload_len: payload.bytesize) + payload
    end

    def self.pack_file_backed(id:, flags:)
      pack_header(id:, flags: flags & ~INLINE, payload_len: 0)
    end

    def self.pack_header(id:, flags:, payload_len:)
      validate_flags!(flags)
      validate_payload_len!(flags, payload_len)

      [flags, id.bytes, payload_len].pack("Ca8n")
    end

    def self.unpack_header(bytes)
      if !bytes.is_a?(String) || bytes.bytesize != HEADER_BYTES
        raise(ArgumentError, "submit header must be #{HEADER_BYTES} bytes")
      end

      flags, id_bytes, payload_len = bytes.unpack("Ca8n")
      validate_flags!(flags)
      validate_payload_len!(flags, payload_len)
      Header.new(flags:, id: Urpc::Id.from_bytes(id_bytes), payload_len:)
    end

    def self.validate_flags!(flags)
      if !flags.is_a?(Integer) || flags.negative? || (flags & ~KNOWN_FLAGS) != 0
        raise(ArgumentError, "unknown submit flag bits: #{flags.inspect}")
      end
      if (flags & CAST) != 0 && (flags & BIDIRECTIONAL) != 0
        raise(ArgumentError, "bidirectional cast not supported")
      end
    end

    def self.validate_payload_len!(flags, payload_len)
      if !payload_len.is_a?(Integer) || payload_len.negative? || payload_len > PAYLOAD_LEN_FIELD_MAX
        raise(ArgumentError, "invalid submit payload length: #{payload_len.inspect}")
      end
      if (flags & INLINE) == 0 && payload_len != 0
        raise(ArgumentError, "file-backed submit payload length must be zero")
      end
      if (flags & INLINE) != 0 && payload_len > INLINE_PAYLOAD_LEN_MAX
        raise(ArgumentError, "inline payload too large: #{payload_len}")
      end
    end
  end
end
