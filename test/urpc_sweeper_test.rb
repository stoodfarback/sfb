# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcSweeperTest < Minitest::Test
  def touch_old(path, seconds_ago: 2 * 60 * 60)
    t = Time.now - seconds_ago
    File.utime(t, t, path)
  end

  def test_sweeper_removes_stale_request_file
    with_broker do
      id = SecureRandom.hex(16)
      path = File.join(Urpc.requests_dir, "#{id}.msgpack")
      File.binwrite(path, MessagePack.pack({ hello: "world" }))
      touch_old(path)

      @broker.sweep!(expiry: 60)
      refute(File.exist?(path))
    end
  end

  def test_sweeper_removes_stale_reply_fifo
    with_broker do
      id = SecureRandom.hex(16)
      path = File.join(Urpc.replies_dir, "#{id}.fifo")
      File.mkfifo(path, 0o600)
      touch_old(path)

      @broker.sweep!(expiry: 60)
      refute(File.exist?(path))
    end
  end

  def test_sweeper_skips_active_ids
    with_broker do
      gate = Queue.new
      handler = Class.new do
        def initialize(gate) = (@gate = gate)
        def hold(req)
          @gate.pop
          req.stream.return("done")
        end
      end.new(gate)

      start_stream_server("hold", handler)
      wait_for_backend("hold")

      client = Urpc::Client.new("hold", timeout: 10)
      s = client.stream(:hold)

      raise("request never became active") if !poll_until { @broker.active_ids.any? }

      active_id = @broker.state_lock.synchronize { @broker.active_ids.keys.first }
      reply_path = File.join(Urpc.replies_dir, "#{active_id}.fifo")
      req_path = File.join(Urpc.requests_dir, "#{active_id}.msgpack")

      touch_old(reply_path)
      File.binwrite(req_path, "x")
      touch_old(req_path)

      @broker.sweep!(expiry: 60)

      assert(File.exist?(reply_path), "active reply fifo should not be reclaimed")
      assert(File.exist?(req_path), "active request file should not be reclaimed")
    ensure
      gate << true rescue nil
      s&.close rescue nil
    end
  end

  def test_sweeper_ignores_enoent_races
    with_broker do
      id = SecureRandom.hex(16)
      path = File.join(Urpc.requests_dir, "#{id}.msgpack")
      File.binwrite(path, "x")
      touch_old(path)

      File.unlink(path)
      @broker.sweep!(expiry: 60)
      assert(true)
    end
  end
end
