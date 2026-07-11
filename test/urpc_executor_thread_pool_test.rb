# frozen_string_literal: true

require_relative("test_helper")

class UrpcExecutorThreadPoolTest < Minitest::Test
  def test_runs_up_to_size_requests_concurrently
    started = Thread::Queue.new
    release = Thread::Queue.new
    handler = proc do |req|
      value = req.args.fetch(0)
      started << value
      release.pop
      req.finish(value)
    end

    with_thread_pool(size: 2, handler:) do |client|
      calls = [:one, :two].map { |value| Thread.new { client.call(:run, value) } }

      assert_equal([:one, :two].sort, [started.pop, started.pop].sort)
      2.times { release << true }
      assert_equal([:one, :two].sort, calls.map(&:value).sort)
    ensure
      2.times { release << true }
      calls&.each(&:join)
    end
  end

  def test_reserves_capacity_before_accepting_another_request
    started = Thread::Queue.new
    release = Thread::Queue.new
    handler = proc do |req|
      value = req.args.fetch(0)
      started << value
      release.pop
      req.finish(value)
    end

    with_thread_pool(size: 1, handler:) do |client|
      first = Thread.new { client.call(:run, :one) }
      assert_equal(:one, started.pop)
      second = Thread.new { client.call(:run, :two) }
      sleep(0.01)

      assert(second.alive?)
      assert(started.empty?)

      release << true
      assert_equal(:one, first.value)
      assert_equal(:two, started.pop)
      release << true
      assert_equal(:two, second.value)
    ensure
      2.times { release << true }
      first&.join
      second&.join
    end
  end

  def test_client_disconnect_keeps_worker_available
    release = Thread::Queue.new
    handler = proc do |req|
      if req.name == :disconnect
        req.data("first")
        release.pop
        req.data("second")
      else
        req.finish("pong")
      end
    end

    with_thread_pool(size: 1, handler:) do |client|
      stream = client.stream(:disconnect)
      assert_equal("first", stream.each.next)
      stream.close
      release << true

      assert_equal("pong", client.call(:ping))
    ensure
      release << true
      close_io(stream)
    end
  end

  def test_close_wakes_server_waiting_for_pool_capacity
    started = Thread::Queue.new
    release = Thread::Queue.new
    handler = proc do |req|
      started << true
      release.pop
      req.finish(nil)
    end

    with_urpc_root do
      executor = Urpc::Executor::ThreadPool.new(size: 1)
      server = Urpc::Server.new("svc", executor:, &handler)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 1)
      call_thread = Thread.new { client.call(:hold) }
      started.pop

      server.close
      server_thread.join(1)

      assert_equal(false, server_thread.alive?)
    ensure
      release << true
      call_thread&.join(1)
      call_thread&.kill if call_thread&.alive?
      close_io(server)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def test_validates_configuration
    assert_raises(ArgumentError) { Urpc::Executor::ThreadPool.new(size: 0) }
  end

  def with_thread_pool(size:, handler:)
    with_urpc_root do
      executor = Urpc::Executor::ThreadPool.new(size:)
      server = Urpc::Server.new("svc", executor:, &handler)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 2)

      yield(client, executor, server)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end
end
