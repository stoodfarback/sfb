# frozen_string_literal: true

module Urpc
  class Id
    BYTE_LENGTH = 8
    HEX_LENGTH = BYTE_LENGTH * 2
    HEX_RE = /\A[0-9a-f]{16}\z/

    attr_accessor(:bytes)

    def initialize(bytes)
      if !bytes.is_a?(String) || bytes.bytesize != BYTE_LENGTH
        raise(ArgumentError, "urpc id must be #{BYTE_LENGTH} bytes")
      end
      self.bytes = bytes.b.freeze
    end

    def self.generate
      new(SecureRandom.random_bytes(BYTE_LENGTH))
    end

    def self.from_hex(hex)
      if !hex.is_a?(String) || !HEX_RE.match?(hex)
        raise(ArgumentError, "urpc id hex must be #{HEX_LENGTH} lowercase hex chars")
      end
      new([hex].pack("H*"))
    end

    def self.from_bytes(bytes)
      new(bytes)
    end

    def hex
      bytes.unpack1("H*")
    end

    def to_s
      hex
    end

    def ==(other)
      other.is_a?(Id) && bytes == other.bytes
    end
  end
end
