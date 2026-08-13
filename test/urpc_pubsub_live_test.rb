# frozen_string_literal: true

require_relative("test_helper")

class UrpcPubsubLiveTest < Minitest::Test
  ASYNC_TIMEOUT_SECONDS = 2
  RETRY_INTERVAL_SECONDS = 0.01

  def test_publish_and_subscribe_round_trip_against_live_server
    topic = nil
    subscriber = nil

    assert_equal(:pong, Sfb::UrpcPubsub.ping)

    token = SecureRandom.hex(16)
    topic = "sfb:integration:urpc_pubsub:#{token}"
    payload = { token:, state: :round_trip }
    events = Thread::Queue.new
    subscriber = Thread.new do
      Sfb::UrpcPubsub.subscribe(topic) do |event_topic, value|
        events << [event_topic, value]
        break(:received)
      end
    end
    subscriber.report_on_exception = false

    publish_until_count(topic, payload, 1)
    assert_equal([topic, payload], Timeout.timeout(ASYNC_TIMEOUT_SECONDS) { events.pop })
    assert_equal(:received, Timeout.timeout(ASYNC_TIMEOUT_SECONDS) { subscriber.value })

    publish_until_count(topic, :cleanup, 0)
    topic = nil
  ensure
    stop_subscriber(subscriber)
    cleanup_failed_subscription(topic)
  end

  def publish_until_count(topic, value, expected_count)
    Timeout.timeout(ASYNC_TIMEOUT_SECONDS) do
      loop do
        if Sfb::UrpcPubsub.publish(topic, value) == expected_count
          return
        end

        sleep(RETRY_INTERVAL_SECONDS)
      end
    end
  end

  def stop_subscriber(subscriber)
    if !subscriber
      return
    end

    if subscriber.alive?
      subscriber.kill
    end
    subscriber.join(ASYNC_TIMEOUT_SECONDS)
  end

  def cleanup_failed_subscription(topic)
    if !topic
      return
    end

    publish_until_count(topic, :cleanup, 0)
  rescue Urpc::TransportError, Timeout::Error
    nil
  end
end
