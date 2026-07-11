# frozen_string_literal: true

module Urpc
  module StreamFrame
    DATA = 0x01
    RETURN = 0x02
    ERROR = 0x03
    INPUT_READY = 0x04

    READY = 0x11
    SYNC = 0x12
    ASYNC = 0x13

    NO_VALUE = Object.new.freeze

    Frame = Data.define(:type, :value)

    ErrorPayload = Data.define(:exception_name, :message, :backtrace) do
      def self.encode(exception)
        [
          exception.class.name || exception.class.to_s,
          exception.message,
          exception.backtrace || [],
        ]
      end

      def self.decode(value)
        if !value.is_a?(Array) || value.size != 3
          raise(ArgumentError, "invalid urpc remote error payload: #{value.inspect}")
        end

        exception_name, message, backtrace = value
        valid = exception_name.is_a?(String) && !exception_name.empty? && message.is_a?(String) && backtrace.is_a?(Array) && backtrace.all? { it.is_a?(String) }
        if !valid
          raise(ArgumentError, "invalid urpc remote error payload: #{value.inspect}")
        end

        new(exception_name:, message:, backtrace:)
      end
    end

    Tag = Data.define(:byte, :type, :payload)

    TAGS = [
      Tag.new(DATA, :data, true),
      Tag.new(RETURN, :return, true),
      Tag.new(ERROR, :error, true),
      Tag.new(INPUT_READY, :input_ready, false),
      Tag.new(READY, :ready, false),
      Tag.new(SYNC, :sync, true),
      Tag.new(ASYNC, :async, true),
    ].freeze

    TAG_BY_BYTE = TAGS.to_h { [it.byte, it] }.freeze
    TAG_BY_TYPE = TAGS.to_h { [it.type, it] }.freeze

    def self.pack(type, value = NO_VALUE)
      tag = TAG_BY_TYPE.fetch(type) { raise(ArgumentError, "unknown stream frame type: #{type.inspect}") }
      if tag.payload
        raise(ArgumentError, "missing payload for stream frame type: #{type}") if value.equal?(NO_VALUE)

        [tag.byte].pack("C") + MessagePack.pack(value)
      else
        if !value.equal?(NO_VALUE)
          raise(ArgumentError, "stream frame type must not have payload: #{type}")
        end

        [tag.byte].pack("C")
      end
    end

    class Parser
      attr_accessor(:buffer, :current_tag, :unpacker)

      def initialize
        self.buffer = String.new(encoding: Encoding::BINARY)
        self.current_tag = nil
        self.unpacker = nil
      end

      def feed(bytes)
        buffer << bytes
        nil
      end

      def each_frame
        if !block_given?
          return enum_for(:each_frame)
        end

        loop do
          frame = read_frame
          break if !frame

          yield(frame)
        end

        nil
      end

      def read_frame
        return read_payload_frame if current_tag
        return if buffer.empty?

        tag = StreamFrame::TAG_BY_BYTE[buffer.getbyte(0)]
        raise(ArgumentError, "unknown stream frame tag: 0x#{buffer.getbyte(0).to_s(16).rjust(2, "0")}") if !tag
        buffer.slice!(0, 1)

        if !tag.payload
          return Frame.new(type: tag.type, value: nil)
        end

        self.current_tag = tag
        self.unpacker = MessagePack::DefaultFactory.unpacker
        read_payload_frame
      end

      def read_payload_frame
        unpacker.feed(buffer)
        buffer.clear

        value = begin
          unpacker.read
        rescue EOFError
          return
        end

        tag = current_tag
        self.buffer = unpacker.buffer.to_s
        self.current_tag = nil
        self.unpacker = nil
        Frame.new(type: tag.type, value:)
      end

      def partial?
        !!current_tag || !buffer.empty?
      end
    end
  end
end
