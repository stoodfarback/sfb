# frozen_string_literal: true

module Urpc
  module Frames
    RESPONSE_TYPES = %i[data return error inbox].freeze
    BACKEND_RESPONSE_TYPES = %i[data return error].freeze
    BACKEND_CONTROL_TYPES = %i[inbox_ready].freeze
    INBOX_TYPES = %i[ready sync async].freeze
    TERMINAL_TYPES = %i[return error].freeze

    def self.frame(type, value)
      payload = value.nil? ? nil : MessagePack.pack(value)
      [type, payload]
    end

    def self.pack(type, value)
      MessagePack.pack(frame(type, value))
    end

    def self.pack_error(exception)
      exception = StandardError.new(exception) if exception.is_a?(String)
      MessagePack.pack(error_frame(exception))
    end

    def self.error_frame(exception)
      exception = StandardError.new(exception) if exception.is_a?(String)
      frame(:error, error_payload(exception))
    end

    def self.error_payload(exception)
      {
        exception: exception.class.to_s,
        message: exception.message,
        backtrace: exception.backtrace || [],
      }
    end

    def self.unpack_payload(raw_payload)
      raw_payload && MessagePack.unpack(raw_payload)
    end

    def self.valid_response_frame?(frame)
      return false if !frame.is_a?(Array) || frame.size != 2
      type, payload = frame
      return false if !RESPONSE_TYPES.include?(type)
      return valid_error_payload?(payload) if type == :error
      valid_payload?(payload)
    end

    def self.valid_backend_response_frame?(frame)
      return false if !frame.is_a?(Array) || frame.size != 2
      type, payload = frame
      return false if !BACKEND_RESPONSE_TYPES.include?(type)
      return valid_error_payload?(payload) if type == :error
      valid_payload?(payload)
    end

    def self.valid_backend_control_frame?(frame)
      return false if !frame.is_a?(Array) || frame.size != 2
      type, payload = frame
      return false if !BACKEND_CONTROL_TYPES.include?(type)
      payload.nil?
    end

    def self.valid_inbox_frame?(frame)
      return false if !frame.is_a?(Array) || frame.size != 2
      type, payload = frame
      return false if !INBOX_TYPES.include?(type)
      return payload.nil? if type == :ready
      valid_payload?(payload)
    end

    def self.valid_payload?(payload)
      return true if payload.nil?
      return false if !payload.is_a?(String)
      unpack_one(payload)
      true
    rescue MessagePack::UnpackError
      false
    end

    def self.valid_error_payload?(payload)
      return false if !payload.is_a?(String)
      error = unpack_one(payload)
      error.is_a?(Hash) &&
        error[:exception].is_a?(String) &&
        error[:message].is_a?(String) &&
        (error[:backtrace].nil? || error[:backtrace].is_a?(Array))
    rescue MessagePack::UnpackError
      false
    end

    def self.unpack_one(payload)
      unpacker = MessagePack::DefaultFactory.unpacker
      unpacker.feed(payload)
      unpacker.full_unpack
    end
  end
end
