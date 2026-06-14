# frozen_string_literal: true

module Urpc
  module SubmitFrame
    SUBMIT_PIPE_BUF = 4096
    # POSIX guarantees writes of <= PIPE_BUF bytes to a pipe are atomic, so 4096
    # is sufficient in principle. The margin is defensive padding — I'd rather
    # not rely on exact boundary behaviour.
    INLINE_HEADROOM_BYTES = 20
    INLINE_FRAME_MAX = SUBMIT_PIPE_BUF - INLINE_HEADROOM_BYTES

    SUBMIT_WIRE_VERSION = 0
    SUBMIT_VERSION_BYTES = 1
    SUBMIT_FLAGS_BYTES = 1
    WIRE_ID_BYTES = 16
    WIRE_NAME_MAX = 255

    SUBMIT_FLAG_INLINE = 0x01
    SUBMIT_FLAG_CAST = 0x02
    SUBMIT_FLAG_BIDIRECTIONAL = 0x04
    KNOWN_SUBMIT_FLAGS = SUBMIT_FLAG_INLINE | SUBMIT_FLAG_CAST | SUBMIT_FLAG_BIDIRECTIONAL

    WAIT_NO_SERVER = 0
    WAIT_FOREVER = 1
    WAIT_TIMEOUT_MS = 2
    WAIT_TIMEOUT_BYTES = 4

    UINT32_MAX = (2 ** 32) - 1

    def self.encode_wait(wait_for_server)
      if wait_for_server == true
        [WAIT_FOREVER].pack("C")
      elsif wait_for_server == false
        [WAIT_NO_SERVER].pack("C")
      else
        ms = (wait_for_server * 1000).round
        return [WAIT_NO_SERVER].pack("C") if ms <= 0
        raise(ArgumentError, "wait_for_server too large: #{wait_for_server}") if ms > UINT32_MAX
        [WAIT_TIMEOUT_MS, ms].pack("CN")
      end
    end

    def self.encode_envelope(id_bin:, flags:, wait_for_server:, rpc_key:, method_name:)
      rpc_key_bytes = encode_name("rpc_key", rpc_key)
      method_bytes = encode_name("method", method_name)
      raise(ArgumentError, "rpc_key empty or too large: #{rpc_key_bytes.bytesize}") if rpc_key_bytes.bytesize < 1 || rpc_key_bytes.bytesize > WIRE_NAME_MAX
      raise(ArgumentError, "method empty or too large: #{method_bytes.bytesize}") if method_bytes.bytesize < 1 || method_bytes.bytesize > WIRE_NAME_MAX

      out = String.new(encoding: Encoding::BINARY)
      out << [SUBMIT_WIRE_VERSION, flags].pack("CC")
      out << id_bin
      out << encode_wait(wait_for_server)
      out << [rpc_key_bytes.bytesize].pack("C") << rpc_key_bytes
      out << [method_bytes.bytesize].pack("C") << method_bytes
      out
    end

    def self.encode_name(label, value)
      text = value.to_s
      utf8 =
        if text.encoding == Encoding::UTF_8
          text.dup
        else
          text.encode(Encoding::UTF_8)
        end
      raise(ArgumentError, "#{label} invalid UTF-8") if !utf8.valid_encoding?
      utf8.b
    rescue EncodingError => e
      raise(ArgumentError, "#{label} invalid UTF-8: #{e.message}")
    end
  end
end
