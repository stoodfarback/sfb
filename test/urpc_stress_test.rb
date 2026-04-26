# frozen_string_literal: true

require_relative("urpc_test_helper")
require("rbconfig")

class UrpcStressTest < Minitest::Test
  def spawn_backend(key)
    ruby = RbConfig.ruby
    code = <<~RUBY
      require("sfb")

      handler = Class.new do
        def echo(x) = x
      end.new

      Urpc::Server.new(#{key.inspect}, handler).run
    RUBY

    Process.spawn(ruby, "-e", code, out: "/dev/null", err: "/dev/null")
  end

  def test_concurrency_stress
    with_root do
      key = "stress"
      n_backends = 4
      m_threads = 20
      calls_per_thread = 50

      broker_pid = spawn_broker
      wait_for_broker

      backend_pids = n_backends.times.map { spawn_backend(key) }

      raise("backends did not register") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:backends][key].to_i >= n_backends
      end

      results = Queue.new
      threads = m_threads.times.map do |i|
        Thread.new do
          client = Urpc::Client.new(key, timeout: 10)
          calls_per_thread.times do |j|
            expected = "t#{i}-#{j}"
            got = client.call(:echo, expected)
            results << (got == expected)
          end
        end
      end

      threads.each(&:join)

      total = m_threads * calls_per_thread
      ok = 0
      total.times { ok += 1 if results.pop }
      assert_equal(total, ok)

      raise("broker did not settle") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:queue_depths][key].to_i == 0 && st[:in_flight][key].to_i == 0
      end

      assert_empty(Dir.children(Urpc.requests_dir))
      assert_empty(Dir.children(Urpc.replies_dir))
    ensure
      (backend_pids || []).each { teardown_process(it) }
      teardown_process(broker_pid)
    end
  end
end
