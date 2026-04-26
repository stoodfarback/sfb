# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcIntrospectionTest < Minitest::Test
  def test_urpc_stats_exposes_backend_queue_and_in_flight
    with_broker do
      gate = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:hold) { gate.pop; "ok" }

      start_server("work", handler)
      start_server("work", handler)
      wait_for_backend("work", count: 2)

      blocker_1 = Thread.new { Urpc::Client.new("work", timeout: 10).call(:hold) }
      blocker_2 = Thread.new { Urpc::Client.new("work", timeout: 10).call(:hold) }

      raise("did not enter in_flight") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:in_flight]["work"] == 2
      end

      queued_thread = Thread.new do
        Urpc::Client.new("work", timeout: 0.2).call(:hold)
      rescue Urpc::TimeoutException
        :timed_out
      end

      raise("did not see queued request") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:queue_depths]["work"] == 1
      end

      st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
      assert_equal(2, st[:backends]["work"])
      assert_equal(2, st[:in_flight]["work"])
      assert_equal(1, st[:queue_depths]["work"])
    ensure
      3.times { gate << true rescue nil }
      blocker_1&.kill rescue nil
      blocker_2&.kill rescue nil
      queued_thread&.kill rescue nil
    end
  end

  def test_external_server_cannot_register_reserved_urpc_key
    with_broker do
      sock = UNIXSocket.open(Urpc.broker_sock)
      sock.write(MessagePack.pack("urpc"))
      sleep(0.05)

      st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
      assert_equal(1, st[:backends]["urpc"])
    ensure
      sock&.close rescue nil
    end
  end
end
