# frozen_string_literal: true

require_relative("test_helper")

class UrpcServerTest < Minitest::Test
  def test_call_round_trips
    handler = proc do |req|
      req.finish(req.args.fetch(0))
    end

    with_running_server(handler) do |client|
      assert_equal("hello", client.call(:echo, "hello"))
    end
  end

  def test_stream_round_trips
    handler = proc do |req|
      name = req.args.fetch(0)
      req.data("#{name}:one")
      req.data("#{name}:two")
      req.finish("done")
    end

    with_running_server(handler) do |client|
      stream = client.stream(:watch, "key")

      assert_equal(["key:one", "key:two"], stream.to_a)
      assert_equal("done", stream.result)
    end
  end

  def test_cast_round_trips
    events = Queue.new
    handler = proc do |req|
      events << req.args.fetch(0)
    end

    with_running_server(handler) do |client|
      assert_nil(client.cast(:log, "event"))
      assert_equal("event", events.pop)
    end
  end

  def test_bidirectional_round_trips
    handler = proc do |req|
      frame = req.next_input
      req.data("got #{frame.value}")
      req.finish("done")
    end

    with_running_server(handler) do |client|
      stream = client.bidirectional(:chat)
      stream.send_sync("hello")

      assert_equal(["got hello"], stream.to_a)
      assert_equal("done", stream.result)
    end
  end

  def test_explicit_error_round_trips
    handler = proc do |req|
      req.error(ArgumentError.new("bad input"))
    end

    with_running_server(handler) do |client|
      error = assert_raises(ArgumentError) { client.call(:boom) }

      assert_equal("bad input", error.message)
    end
  end

  def test_explicit_close_surfaces_server_disconnected
    handler = proc do |req|
      req.close
    end

    with_running_server(handler) do |client|
      error = assert_raises(Urpc::ServerDisconnected) { client.call(:abandon) }

      assert_equal("urpc server disconnected before terminal response", error.message)
    end
  end

  def test_request_can_outlive_handler_block
    requests = Queue.new
    handler = proc do |req|
      requests << req
    end

    with_running_server(handler) do |client|
      result_thread = Thread.new { client.call(:later) }
      req = requests.pop

      assert_equal(false, req.finished?)
      assert_nil(req.finish("done later"))
      assert_equal("done later", result_thread.value)
    ensure
      result_thread&.join
    end
  end

  def test_client_disconnect_abandons_only_that_request
    release = Queue.new
    handler = proc do |req|
      if req.name == :disconnect
        req.data("first")
        release.pop
        req.data("second")
      else
        req.finish("pong")
      end
    end

    with_running_server(handler) do |client|
      stream = client.stream(:disconnect)
      values = stream.each
      assert_equal("first", values.next)

      stream.close
      release << true

      assert_equal("pong", client.call(:ping))
    ensure
      release << true
      stream&.close
    end
  end

  def test_handler_exception_escapes_run
    with_urpc_root do
      server = Urpc::Server.new("svc") do |_req|
        raise("handler failed")
      end
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 1)

      client.cast(:boom)
      error = assert_raises(RuntimeError) { server_thread.value }

      assert_equal("handler failed", error.message)
      assert(server.closed?)
      assert(File.directory?(server.paths.dir))
    ensure
      close_io(server)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def test_server_requires_handler_block
    with_urpc_root do
      assert_raises(ArgumentError) { Urpc::Server.new("svc") }
    end
  end

  def test_server_requires_executor_base
    with_urpc_root do
      error = assert_raises(ArgumentError) { Urpc::Server.new("svc", executor: Object.new) { } }

      assert_equal("urpc executor must be an Urpc::Executor::Base", error.message)
    end
  end

  def test_close_stops_run_loop
    with_urpc_root do
      server = Urpc::Server.new("svc") { }
      thread = Thread.new { server.run }

      server.close
      thread.join(1)

      assert_equal(false, thread.alive?)
      assert(server.closed?)
      assert(File.directory?(server.paths.dir))
    ensure
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_removes_service_dir_after_run
    with_urpc_root do
      server = Urpc::Server.new("svc", temporary: true) { }
      thread = Thread.new { server.run }

      assert(File.directory?(server.paths.dir))
      server.close
      thread.join(1)

      assert_equal(false, thread.alive?)
      assert_equal(false, File.exist?(server.paths.dir))
    ensure
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_removes_service_dir_after_run_error
    with_urpc_root do
      server = Urpc::Server.new("svc", temporary: true) do |_req|
        raise("handler failed")
      end
      thread = Thread.new { server.run }
      thread.report_on_exception = false

      Urpc::Client.new("svc").cast(:boom)
      error = assert_raises(RuntimeError) { thread.value }

      assert_equal("handler failed", error.message)
      assert_equal(false, File.exist?(server.paths.dir))
    ensure
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_cleanup_error_does_not_replace_run_error
    with_urpc_root do
      started = Queue.new
      release = Queue.new
      server = Urpc::Server.new("svc", temporary: true) do |_req|
        started << true
        release.pop
        raise("handler failed")
      end
      thread = Thread.new { server.run }
      thread.report_on_exception = false

      Urpc::Client.new("svc").cast(:boom)
      started.pop
      error = nil
      _stdout, stderr = capture_io do
        with_unwritable_urpc_root do
          release << true
          error = assert_raises(RuntimeError) { thread.value }
        end
      end

      assert_equal("handler failed", error.message)
      assert_includes(stderr, "urpc server shutdown also failed: Errno::EACCES:")
      assert(File.directory?(server.paths.dir))
    ensure
      release&.push(true)
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_cleanup_error_escapes_successful_run_called_from_rescue
    with_urpc_root do
      started = Queue.new
      release = Queue.new
      server = Urpc::Server.new("svc", temporary: true) do |_req|
        started << true
        release.pop
      end
      thread = Thread.new do
        raise("outer failure")
      rescue
        server.run
      end
      thread.report_on_exception = false

      Urpc::Client.new("svc").cast(:block)
      started.pop
      server.close
      with_unwritable_urpc_root do
        release << true
        assert_raises(Errno::EACCES) { thread.value }
      end

      assert(File.directory?(server.paths.dir))
    ensure
      release&.push(true)
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_removes_service_dir_when_run_thread_is_killed
    with_urpc_root do
      started = Queue.new
      server = Urpc::Server.new("svc", temporary: true) do |_req|
        started << true
        sleep
      end
      thread = Thread.new { server.run }

      Urpc::Client.new("svc").cast(:block)
      started.pop
      thread.kill
      thread.join

      assert_equal(false, File.exist?(server.paths.dir))
    ensure
      close_io(server)
      thread&.kill if thread&.alive?
    end
  end

  def test_temporary_server_cleanup_does_not_remove_replacement_server
    with_urpc_root do
      temporary = Urpc::Server.new("svc", temporary: true) { }
      temporary.close
      replacement = Urpc::Server.new("svc") { |req| req.finish("replacement") }
      replacement_thread = Thread.new { replacement.run }

      temporary.run

      client = Urpc::Client.new("svc", timeout: 1)
      assert_equal("replacement", client.call(:ping))
    ensure
      close_io(temporary)
      close_io(replacement)
      replacement_thread&.join(1)
      replacement_thread&.kill if replacement_thread&.alive?
    end
  end

  def test_failed_temporary_server_constructor_preserves_owned_server
    with_urpc_root do
      first = Urpc::Server.new("svc") { |req| req.finish("first") }
      first_thread = Thread.new { first.run }

      error = assert_raises(RuntimeError) { Urpc::Server.new("svc", temporary: true) { } }

      assert_match(/already running/, error.message)
      assert(File.directory?(first.paths.dir))
      assert_equal("first", Urpc::Client.new("svc", timeout: 1).call(:ping))
    ensure
      close_io(first)
      first_thread&.join(1)
      first_thread&.kill if first_thread&.alive?
    end
  end

  def test_server_lock_is_exclusive
    with_urpc_root do
      first = Urpc::Server.new("svc") { }

      assert_raises(RuntimeError) { Urpc::Server.new("svc") { } }

      first.close
      second = Urpc::Server.new("svc") { }
      assert(second)
    ensure
      close_io(first)
      close_io(second)
    end
  end

  def with_running_server(handler)
    with_urpc_root do
      server = Urpc::Server.new("svc", &handler)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      yield(client)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def with_unwritable_urpc_root
    original_mode = File.stat(Urpc.root).mode & 0o777
    File.chmod(0o500, Urpc.root)
    yield
  ensure
    File.chmod(original_mode, Urpc.root)
  end
end
