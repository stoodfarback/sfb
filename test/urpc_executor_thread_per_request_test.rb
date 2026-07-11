# frozen_string_literal: true

require_relative("test_helper")

class UrpcExecutorThreadPerRequestTest < Minitest::Test
  def test_starts_each_request_in_its_own_thread
    started = Thread::Queue.new
    release = Thread::Queue.new
    handler = proc do |req|
      value = req.args.fetch(0)
      started << [value, Thread.current]
      release.pop
      req.finish(value)
    end

    with_thread_per_request(handler:) do |client|
      calls = [:one, :two].map { |value| Thread.new { client.call(:run, value) } }
      first, second = [started.pop, started.pop]

      assert_equal([:one, :two].sort, [first.first, second.first].sort)
      refute_same(first.last, second.last)

      2.times { release << true }
      assert_equal([:one, :two].sort, calls.map(&:value).sort)
    ensure
      2.times { release << true }
      calls&.each(&:join)
    end
  end

  def test_client_disconnect_does_not_abort_server
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

    with_thread_per_request(handler:) do |client|
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

  def test_stalled_bidirectional_handshake_does_not_block_acceptance
    ping_seen = Thread::Queue.new
    dispatch = Urpc::Dispatch.new(
      chat: -> { :chat },
      ping: -> do
        ping_seen << true
        :pong
      end,
    )

    with_thread_per_request(handler: dispatch) do |client|
      stalled = client.bidirectional(:chat)
      wait_for_path_removal(stalled.paths.output_fifo(stalled.id))
      ping_thread = Thread.new { client.call(:ping) }

      Timeout.timeout(0.25) { ping_seen.pop }
      assert_equal(:pong, ping_thread.value)
      assert_equal(:chat, stalled.result)
    ensure
      close_io(stalled)
      ping_thread&.join(1)
      ping_thread&.kill if ping_thread&.alive?
    end
  end

  def with_thread_per_request(handler:)
    with_urpc_root do
      executor = Urpc::Executor::ThreadPerRequest.new
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

  def wait_for_path_removal(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      return if !File.exist?(path)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise("timed out waiting for #{path} removal")
      end
      Thread.pass
    end
  end
end
