# frozen_string_literal: true

module Sfb
  module UrpcPubsub
    RPC_KEY = "urpc_pubsub_v1"

    CLIENT_WAIT_FOR_SERVER_SECONDS = 1
    CLIENT_TIMEOUT_SECONDS = 1

    MAX_TOPIC_BYTES = 255
    MAX_SUBSCRIPTION_TOPICS = 256

    READY = :ready
    EVENT = :event
    HEARTBEAT_FRAME = [:heartbeat].freeze

    class << self
      extend(Sfb::Memo)

      def publish(topic, value)
        rpc_client.call(:publish, normalize_topic(topic), value)
      end

      def subscribe(*topics, &block)
        if !block
          raise(ArgumentError, "Sfb::UrpcPubsub.subscribe requires a block")
        end

        run_subscription(normalize_topics(topics), block:, watch: false)
      end

      def watch(*topics, &block)
        if !block
          raise(ArgumentError, "Sfb::UrpcPubsub.watch requires a block")
        end

        run_subscription(normalize_topics(topics), block:, watch: true)
      end

      def ping
        rpc_client.call(:ping)
      end

      def stats
        rpc_client.call(:stats)
      end

      def run_subscription(topics, block:, watch:)
        stream = rpc_client.stream(:subscribe, *topics)
        ready = false

        begin
          stream.each do |frame|
            if !ready
              validate_ready_frame!(frame, topics)
              stream.reader.deadline = nil
              ready = true
              block.call if watch
              next
            end

            next if frame == HEARTBEAT_FRAME

            validate_event_frame!(frame, topics)
            if watch
              block.call
            else
              block.call(frame[1], frame[2])
            end
          end

          message = ready ? "urpc_pubsub subscription ended unexpectedly" : "urpc_pubsub subscription ended before ready"
          raise(message)
        ensure
          stream.close
        end
      end

      def validate_ready_frame!(frame, topics)
        if frame != [READY, topics]
          raise("invalid urpc_pubsub ready frame: #{frame.inspect}")
        end
      end

      def validate_event_frame!(frame, topics)
        valid = frame.is_a?(Array) && frame.length == 3 && frame[0] == EVENT && topics.include?(frame[1])
        if !valid
          raise("invalid urpc_pubsub subscription frame: #{frame.inspect}")
        end
      end

      def normalize_topic(topic)
        text = topic.to_s
        normalized = if text.encoding == Encoding::ASCII_8BIT
          text.dup.force_encoding(Encoding::UTF_8)
        else
          text.encode(Encoding::UTF_8)
        end

        if normalized.empty?
          raise(ArgumentError, "urpc_pubsub topic must not be empty")
        end
        if !normalized.valid_encoding?
          raise(ArgumentError, "urpc_pubsub topic must be valid UTF-8")
        end
        if normalized.bytesize > MAX_TOPIC_BYTES
          raise(ArgumentError, "urpc_pubsub topic must be at most #{MAX_TOPIC_BYTES} bytes")
        end

        normalized.freeze
      rescue EncodingError, TypeError => e
        raise(ArgumentError, "urpc_pubsub topic must be valid UTF-8: #{e.message}")
      end

      def normalize_topics(topics)
        if topics.empty?
          raise(ArgumentError, "urpc_pubsub subscription requires at least one topic")
        end

        normalized_topics = topics.map { normalize_topic(it) }.uniq
        if normalized_topics.length > MAX_SUBSCRIPTION_TOPICS
          raise(ArgumentError, "urpc_pubsub subscription may contain at most #{MAX_SUBSCRIPTION_TOPICS} distinct topics")
        end

        normalized_topics.freeze
      end

      memo def rpc_client
        Urpc::Client.new(
          RPC_KEY,
          timeout: CLIENT_TIMEOUT_SECONDS,
          wait_for_server: CLIENT_WAIT_FOR_SERVER_SECONDS,
        )
      end
    end
  end
end
