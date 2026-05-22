# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcFailuresTest < Minitest::Test
  def echo_handler
    Class.new do
      def echo(x) = x
      def slow(ms) = (sleep(ms / 1000.0); "slow-done")
    end.new
  end

  def test_basic_handler_unencodable_return_sends_error_and_backend_remains_usable
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:bad_return) { Object.new }
      handler.singleton_class.define_method(:echo) {|value| value }

      start_server("unencodable_basic", handler)
      wait_for_backend("unencodable_basic")

      client = Urpc::Client.new("unencodable_basic", timeout: 1)
      e = assert_raises(NoMethodError) { client.call(:bad_return) }
      assert_match(/to_msgpack/, e.message)
      assert_equal("ok", client.call(:echo, "ok"))
    end
  end

  def test_stream_return_unencodable_sends_error_and_backend_remains_usable
    with_broker do
      handler = Class.new do
        def bad_return(req)
          req.stream.return(Object.new)
        end

        def echo(req)
          req.stream.return(req.args.first)
        end
      end.new

      start_stream_server("unencodable_stream", handler)
      wait_for_backend("unencodable_stream")

      client = Urpc::Client.new("unencodable_stream", timeout: 1)
      e = assert_raises(NoMethodError) { client.call(:bad_return) }
      assert_match(/to_msgpack/, e.message)
      assert_equal("ok", client.call(:echo, "ok"))
    end
  end

  def test_internal_response_stream_can_error_after_unencodable_return
    with_broker do
      io = StringIO.new
      stream = Urpc::ResponseStream.new(sink: Urpc::ResponseStream::Sinks::Socket.new(io))

      e = assert_raises(NoMethodError) { stream.return(Object.new) }
      assert_match(/to_msgpack/, e.message)
      refute(stream.is_finished)

      stream.error("encoded error")
      assert(stream.is_finished)

      frames = []
      unpacker = MessagePack::DefaultFactory.unpacker
      unpacker.feed(io.string)
      unpacker.each {|frame| frames << frame }

      assert_equal(:error, frames.last[0])
      payload = MessagePack.unpack(frames.last[1])
      assert_equal("encoded error", payload[:message])
    end
  end

  def test_response_stream_terminal_state_is_guarded_by_write_lock
    first_entered = Queue.new
    second_waiting = Queue.new
    release_first = Queue.new
    mutex = Mutex.new
    cv = ConditionVariable.new
    locked = false
    entries = 0

    gate_lock = Object.new
    gate_lock.define_singleton_method(:synchronize) do |&block|
      entry_number = nil
      mutex.synchronize do
        entries += 1
        entry_number = entries
        if locked
          second_waiting << true
          cv.wait(mutex) while locked
        else
          locked = true
          first_entered << true if entry_number == 1
        end
        locked = true
      end

      release_first.pop if entry_number == 1
      block.call
    ensure
      mutex.synchronize do
        locked = false
        cv.broadcast
      end
    end

    writes = Queue.new
    sink = Object.new
    sink.define_singleton_method(:write_response) {|type, value| writes << [type, value] }
    sink.define_singleton_method(:write_error) {|exception| writes << [:error, exception] }

    stream = Urpc::ResponseStream.new(sink:)
    stream.write_lock = gate_lock

    results = Queue.new
    first = Thread.new do
      stream.return("first")
      results << [:first, :ok]
    rescue => e
      results << [:first, e]
    end

    first_entered.pop

    second = Thread.new do
      stream.return("second")
      results << [:second, :ok]
    rescue => e
      results << [:second, e]
    end

    second_waiting.pop
    release_first << true

    first.join
    second.join

    outcomes = 2.times.to_h { results.pop }
    assert_equal(:ok, outcomes.fetch(:first))
    assert_equal("double-finish", outcomes.fetch(:second).message)
    assert_equal([[:return, "first"]], [writes.pop])
    assert(writes.empty?)
  end

  def test_response_frame_validation_accepts_inbox_but_not_inbox_messages
    assert(Urpc::Frames.valid_response_frame?(Urpc::Frames.frame(:inbox, "/tmp/urpc-inbox")))
    refute(Urpc::Frames.valid_backend_response_frame?(Urpc::Frames.frame(:inbox, "/tmp/urpc-inbox")))
    assert(Urpc::Frames.valid_backend_control_frame?(Urpc::Frames.frame(:inbox_ready, nil)))
    refute(Urpc::Frames.valid_backend_control_frame?(Urpc::Frames.frame(:inbox_ready, "path")))
    refute(Urpc::Frames.valid_response_frame?(Urpc::Frames.frame(:sync, "value")))
    refute(Urpc::Frames.valid_response_frame?(Urpc::Frames.frame(:async, "value")))
    assert(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:ready, nil)))
    refute(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:ready, "value")))
    assert(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:sync, "value")))
    assert(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:async, "value")))
    refute(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:inbox, "/tmp/urpc-inbox")))
    refute(Urpc::Frames.valid_inbox_frame?(Urpc::Frames.frame(:return, "value")))
  end

  def test_null_response_stream_ignores_unencodable_values
    with_broker do
      stream = Urpc::ResponseStream.new(sink: Urpc::ResponseStream::Sinks::Null.new)

      stream.return(Object.new)

      assert(stream.is_finished)
    end
  end

  def test_remote_exception_hydration_preserves_remote_backtrace
    with_broker do
      client = Urpc::Client.new("remote_exception")
      e = client.hydrate_error(
        exception: Urpc::RemoteException.to_s,
        message: "remote failed",
        backtrace: ["remote.rb:1"],
      )

      assert_kind_of(Urpc::RemoteException, e)
      assert_equal(["remote.rb:1"], e.remote_backtrace)
    end
  end

  def test_stream_server_rejects_malformed_broker_frame
    with_broker do
      called = false
      handler = Object.new
      handler.singleton_class.define_method(:whatever) do |_req|
        called = true
      end

      server = Urpc::StreamServer.new("malformed_broker_frame", handler)
      unpacker = Object.new
      unpacker.define_singleton_method(:read) { { name: :whatever, args: "not an array", kargs: {} } }

      e = assert_raises(MessagePack::UnpackError) { server.run_one(unpacker) }
      assert_match(/malformed broker request frame/, e.message)
      refute(called)
    end
  end

  def test_stream_server_does_not_warn_about_reconnect_after_shutdown
    with_broker do
      handler = Object.new
      server = Urpc::StreamServer.new("shutdown_reconnect_warning", handler)
      thread = Thread.new { server.run }
      thread.report_on_exception = false
      @server_threads << thread

      wait_for_backend("shutdown_reconnect_warning")
      $stderr.string = ""

      server.shutdown = true
      server.sock&.close rescue nil

      raise("server did not stop") if !thread.join(1)
      thread.value

      refute_match(/connection lost/, $stderr.string)
    end
  end

  def test_backend_registration_creates_queue_before_worker_start
    with_broker do
      broker = Urpc::Broker.new
      started = false
      fake_backend = Object.new
      fake_backend.define_singleton_method(:start) { started = true }

      Urpc::Backend.stub(:new, fake_backend) do
        broker.register_backend("registration_race", Object.new, Object.new)
      end

      assert(started)
      assert(broker.state_lock.synchronize { broker.queues_by_key.key?("registration_race") })
    end
  end

  def test_introspection_registration_creates_queue_before_worker_start
    with_broker do
      broker = Urpc::Broker.new
      started = false
      fake_backend = Object.new
      fake_backend.define_singleton_method(:start) { started = true }

      Urpc::InternalBackend.stub(:new, fake_backend) do
        broker.register_introspection_backend
      end

      assert(started)
      assert(broker.state_lock.synchronize { broker.queues_by_key.key?(Urpc::RESERVED_KEY) })
    end
  end

  def test_synthesize_error_reply_unlinks_fifo_when_client_is_gone
    with_broker do
      reply_path = nil
      id = SecureRandom.hex(16)
      reply_path = File.join(Urpc.replies_dir, "#{id}.fifo")
      File.mkfifo(reply_path)

      @broker.synthesize_error_reply(id, Urpc::RemoteException, "client gone")

      refute(File.exist?(reply_path))
    end
  end

  def test_reply_path_not_fifo
    with_broker do
      req_path = nil
      reply_path = nil
      called = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:echo) do |x|
        called << x
        x
      end

      start_server("reply_path_not_fifo", handler)
      wait_for_backend("reply_path_not_fifo")

      call = Urpc::Call.new(
        id: SecureRandom.hex(16),
        rpc_key: "reply_path_not_fifo",
        name: :echo,
        args: ["hello"],
        kargs: {},
        cast: false,
        wait_for_server: false,
      )
      req_path = call.request_path
      reply_path = call.reply_path

      File.write(reply_path, "not a fifo")
      File.write(req_path, call.body_payload)

      client = Urpc::Client.new("reply_path_not_fifo", timeout: 0.5)
      envelope = client.build_envelope(call, inline: false)
      client.write_frame(envelope)

      sleep(0.5)
      assert(called.empty?, "handler should not have been invoked")
      assert_equal("not a fifo", File.read(reply_path))

      in_flight = @broker.state_lock.synchronize { @broker.in_flight_by_key["reply_path_not_fifo"] || 0 }
      assert_equal(0, in_flight)
    end
  end

  def test_structural_malformed_backend_frame
    with_broker do
      # Valid MessagePack but invalid frame shape
      fake_server_thread = Thread.new do
        sock = UNIXSocket.open(Urpc.broker_sock)
        sock.write(MessagePack.pack("structural_malformed_key"))

        unpacker = MessagePack::DefaultFactory.unpacker(sock)
        _request = unpacker.read

        # Valid msgpack, but not an array of size 2
        sock.write(MessagePack.pack([:bogus, nil, :extra]))
        sleep(1)
        sock.close rescue nil
      end

      raise("fake backend did not register") if !poll_until { @broker.backend_count("structural_malformed_key") >= 1 }

      client = Urpc::Client.new("structural_malformed_key", timeout: 5)
      assert_raises { client.call(:whatever) }

      sleep(0.2)
      assert_equal(0, @broker.backend_count("structural_malformed_key"))
    ensure
      fake_server_thread&.kill rescue nil
    end
  end

  def test_preflight_broker_unavailable_missing_root
    with_broker do
      @broker.stop
      sleep(0.05)
      FileUtils.rm_rf(Urpc.root)

      client = Urpc::Client.new("whatever", timeout: 1)
      e = assert_raises(Urpc::BrokerUnavailable) { client.call(:echo, "hi") }
      assert_match(/root/i, e.message)

      FileUtils.mkdir_p(Urpc.root)
    end
  end

  def test_preflight_broker_unavailable_missing_sock
    with_broker do
      @broker.stop
      sleep(0.05)
      # Remove broker.sock but leave in.fifo
      File.unlink(Urpc.broker_sock) rescue nil

      client = Urpc::Client.new("whatever", timeout: 1)
      e = assert_raises(Urpc::BrokerUnavailable) { client.call(:echo, "hi") }
      assert_match(/socket/i, e.message)
    end
  end

  def test_preflight_broker_unavailable_missing_fifo
    with_broker do
      @broker.stop
      sleep(0.05)
      # broker.stop removes both sock and fifo; recreate sock so we hit the fifo check
      File.unlink(Urpc.in_fifo) rescue nil
      dummy_sock = UNIXServer.new(Urpc.broker_sock)

      client = Urpc::Client.new("whatever", timeout: 1)
      e = assert_raises(Urpc::BrokerUnavailable) { client.call(:echo, "hi") }
      assert_match(/fifo/i, e.message)
    ensure
      dummy_sock&.close rescue nil
    end
  end

  def test_no_server_non_cast_raises
    with_broker do
      client = Urpc::Client.new("no_such_key", timeout: 5)
      assert_raises(Urpc::NoServerError) { client.call(:whatever) }
    end
  end

  def test_no_server_cast_drops
    with_broker do
      client = Urpc::Client.new("no_cast_key", timeout: 5)
      assert_nil(client.cast(:whatever, 1, 2))
      sleep(0.05)
      # No artifacts left behind
      request_files = Dir.glob(File.join(Urpc.requests_dir, "*.msgpack"))
      assert_empty(request_files)
    end
  end

  def test_wait_for_server_cast_queues_until_backend_registers
    with_broker do
      received = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:record) do |value|
        received << value
        nil
      end

      client = Urpc::Client.new("wait_cast_key", timeout: 5, wait_for_server: true)
      assert_equal(0, @broker.backend_count("wait_cast_key"))
      assert_nil(client.cast(:record, "later"))

      raise("cast was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_cast_key"]&.size || 0) == 1 }
      }
      assert(received.empty?)

      start_server("wait_cast_key", handler)
      wait_for_backend("wait_cast_key")

      raise("cast did not arrive") if !poll_until { !received.empty? }
      assert_equal("later", received.pop)
    end
  end

  def test_wait_for_server_numeric_times_out_with_no_server
    with_broker do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      e = assert_raises(Urpc::NoServerError) do
        Urpc::Client.new("wait_numeric_missing", timeout: 2, wait_for_server: 0.3).call(:whatever)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_match(/no server registered/, e.message)
      assert_operator(elapsed, :>=, 0.2)
      assert_operator(elapsed, :<, 1.2)
    end
  end

  def test_wait_for_server_numeric_dispatches_when_backend_appears_in_time
    with_broker do
      handler = echo_handler
      call_thread = Thread.new do
        Urpc::Client.new("wait_numeric_later", timeout: 2, wait_for_server: 2).call(:echo, "ok")
      end

      raise("call was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_numeric_later"]&.size || 0) == 1 }
      }

      sleep(0.2)
      start_server("wait_numeric_later", handler)
      wait_for_backend("wait_numeric_later")

      assert_equal("ok", call_thread.value)
    ensure
      call_thread&.kill rescue nil
    end
  end

  def test_wait_for_server_numeric_stale_backend_times_out_without_replacement
    with_broker do
      handler = echo_handler
      start_server("wait_numeric_stale_timeout", handler)
      wait_for_backend("wait_numeric_stale_timeout")

      @server_threads.pop.kill rescue nil
      sleep(0.3)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      e = assert_raises(Urpc::NoServerError) do
        Urpc::Client.new("wait_numeric_stale_timeout", timeout: 5, wait_for_server: 0.3).call(:echo, "late")
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_match(/no server registered/, e.message)
      assert_operator(elapsed, :<, 1.5)
    end
  end

  def test_wait_for_server_numeric_stale_backend_requeues_to_replacement_before_deadline
    with_broker do
      handler = echo_handler
      start_server("wait_numeric_stale_requeue", handler)
      wait_for_backend("wait_numeric_stale_requeue")

      @server_threads.pop.kill rescue nil
      sleep(0.3)

      call_thread = Thread.new do
        Urpc::Client.new("wait_numeric_stale_requeue", timeout: 3, wait_for_server: 2).call(:echo, "delayed")
      end

      sleep(0.4)
      start_server("wait_numeric_stale_requeue", handler)
      wait_for_backend("wait_numeric_stale_requeue")

      assert_equal("delayed", call_thread.value)
    ensure
      call_thread&.kill rescue nil
    end
  end

  def test_wait_for_server_rejects_invalid_numeric_values
    build_call = ->(wait_for_server) do
      Urpc::Call.new(
        id: SecureRandom.hex(16),
        rpc_key: "invalid_wait",
        name: :echo,
        args: [],
        kargs: {},
        cast: false,
        wait_for_server: wait_for_server,
      )
    end

    assert_raises(ArgumentError) { build_call.call(-0.1) }
    assert_raises(ArgumentError) { build_call.call(Float::INFINITY) }
    assert_raises(ArgumentError) { build_call.call(Float::NAN) }
  end

  def test_wait_for_server_zero_matches_false
    with_broker do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Urpc::NoServerError) do
        Urpc::Client.new("wait_zero", timeout: 2, wait_for_server: 0).call(:whatever)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator(elapsed, :<, 0.5)
      assert_equal(0, @broker.state_lock.synchronize { @broker.wait_calls_by_id.size })
    end
  end

  def test_wait_for_server_numeric_does_not_expire_when_backend_is_busy
    with_broker do
      gate = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:slow) do |x|
        gate.pop
        x
      end
      handler.singleton_class.define_method(:echo) {|x| x }

      start_server("wait_busy_backend", handler)
      wait_for_backend("wait_busy_backend")

      busy_thread = Thread.new do
        Urpc::Client.new("wait_busy_backend", timeout: 5).call(:slow, "first")
      end

      raise("busy call did not start") if !poll_until {
        @broker.state_lock.synchronize { @broker.in_flight_by_key["wait_busy_backend"] == 1 }
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      second_thread = Thread.new do
        Urpc::Client.new("wait_busy_backend", timeout: 3, wait_for_server: 0.2).call(:echo, "second")
      end

      raise("second call was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_busy_backend"]&.size || 0) == 1 }
      }

      assert_equal(0, @broker.state_lock.synchronize { @broker.wait_calls_by_id.size })

      sleep(0.4)
      gate << true
      assert_equal("first", busy_thread.value)
      assert_equal("second", second_thread.value)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert_operator(elapsed, :>=, 0.4)
    ensure
      busy_thread&.kill rescue nil
      second_thread&.kill rescue nil
    end
  end

  def test_wait_for_server_numeric_starts_budget_when_only_backend_disappears
    with_broker do
      gate = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:slow) do |x|
        gate.pop
        x
      end
      handler.singleton_class.define_method(:echo) {|x| x }

      start_server("wait_disappears", handler)
      wait_for_backend("wait_disappears")

      busy_thread = Thread.new do
        Urpc::Client.new("wait_disappears", timeout: 5).call(:slow, "busy") rescue nil
      end

      raise("busy call did not start") if !poll_until {
        @broker.state_lock.synchronize { @broker.in_flight_by_key["wait_disappears"] == 1 }
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      victim_thread = Thread.new do
        Urpc::Client.new("wait_disappears", timeout: 5, wait_for_server: 0.3).call(:echo, "victim")
      rescue => e
        e
      end

      raise("victim was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_disappears"]&.size || 0) == 1 }
      }

      @broker.state_lock.synchronize do
        (@broker.backends_by_key["wait_disappears"] || []).each { it.sock.close rescue nil }
      end

      result = victim_thread.value
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_kind_of(Urpc::NoServerError, result)
      assert_operator(elapsed, :>=, 0.2)
      assert_operator(elapsed, :<, 1.5)
    ensure
      gate << true rescue nil
      busy_thread&.kill rescue nil
      victim_thread&.kill rescue nil
    end
  end

  def test_wait_for_server_numeric_budget_anchored_to_received_at_in_drain
    broker = Urpc::Broker.new
    backend = Object.new
    backend.define_singleton_method(:key) { "wait_anchor" }

    request_call = Urpc::Call.new(
      id: SecureRandom.hex(16),
      rpc_key: "wait_anchor",
      name: :echo,
      args: ["x"],
      kargs: {},
      cast: true,
      wait_for_server: 0.3,
    )
    broker_call = Urpc::BrokerCall.new(call: request_call, received_at: broker.monotonic_now - 1.0)

    drained = broker.state_lock.synchronize do
      broker.backends_by_key["wait_anchor"] = [backend]
      broker.active_ids[broker_call.id] = "wait_anchor"
      (broker.queues_by_key["wait_anchor"] ||= Queue.new) << broker_call

      broker.remove_backend_locked(backend)
      broker.drain_queued_calls_if_no_backends_locked("wait_anchor")
    end

    assert_equal(1, drained.size)
    assert_equal(broker_call.id, drained.first.id)
    assert_in_delta(broker_call.received_at + 0.3, broker_call.wait_deadline, 0.001)
  end

  def test_wait_expiry_recomputes_after_earliest_deadline_removed
    with_broker do
      handler = echo_handler
      first_thread = Thread.new do
        Urpc::Client.new("wait_recompute_first", timeout: 2, wait_for_server: 0.5).call(:echo, "first")
      end
      raise("first call was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_recompute_first"]&.size || 0) == 1 }
      }

      second_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      second_thread = Thread.new do
        Urpc::Client.new("wait_recompute_second", timeout: 2, wait_for_server: 0.9).call(:echo, "second")
      rescue => e
        e
      end
      raise("second call was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_recompute_second"]&.size || 0) == 1 }
      }

      start_server("wait_recompute_first", handler)
      wait_for_backend("wait_recompute_first")
      assert_equal("first", first_thread.value)

      result = second_thread.value
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - second_started_at

      assert_kind_of(Urpc::NoServerError, result)
      assert_operator(elapsed, :>=, 0.7)
      assert_operator(elapsed, :<, 1.8)
    ensure
      first_thread&.kill rescue nil
      second_thread&.kill rescue nil
    end
  end

  def test_broker_stop_wakes_wait_expiry_thread
    with_broker do
      call_thread = Thread.new do
        Urpc::Client.new("wait_stop", timeout: 0, wait_for_server: 30).call(:whatever)
      rescue => e
        e
      end

      raise("call was not queued") if !poll_until {
        @broker.state_lock.synchronize { (@broker.queues_by_key["wait_stop"]&.size || 0) == 1 }
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @broker.stop
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator(elapsed, :<, 0.75)
    ensure
      call_thread&.kill rescue nil
    end
  end

  def test_client_timeout_before_dispatch
    with_broker do
      invoked = Queue.new
      gate = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:slow_method) do |x|
        invoked << x
        gate.pop
        x
      end

      start_server("timeout_pre", handler)
      wait_for_backend("timeout_pre")

      busy_thread = Thread.new do
        busy_client = Urpc::Client.new("timeout_pre", timeout: 10)
        busy_client.call(:slow_method, "blocking") rescue nil
      end

      raise("server never got busy") if !poll_until { !invoked.empty? }

      client = Urpc::Client.new("timeout_pre", timeout: 0.2)
      assert_raises(Urpc::TimeoutException) { client.call(:slow_method, "should_not_run") }

      gate << true
      busy_thread.value
      sleep(0.3)

      assert_equal(1, invoked.size)
    ensure
      2.times { gate << true rescue nil }
      busy_thread&.kill rescue nil
    end
  end

  def test_client_timeout_after_dispatch_backend_stays
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:slow_op) {|ms| sleep(ms / 1000.0); "done" }

      start_server("timeout_post", handler)
      wait_for_backend("timeout_post")

      client = Urpc::Client.new("timeout_post", timeout: 0.1)
      assert_raises(Urpc::TimeoutException) { client.call(:slow_op, 500) }

      # Backend should still be registered and able to serve later calls
      # Wait for the previous slow call to finish / backend to recover
      sleep(0.7)
      assert(@broker.backend_count("timeout_post") >= 1, "backend should still be registered")

      # Subsequent call should succeed
      client2 = Urpc::Client.new("timeout_post", timeout: 5)
      assert_equal("done", client2.call(:slow_op, 10))
    end
  end

  def test_backend_death_mid_call
    with_broker do
      dying_handler = Class.new do
        def die_after_data(req)
          req.stream.data("before_crash")
          raise(IOError, "backend crashed")
        end
      end.new

      start_stream_server("die_mid", dying_handler)
      wait_for_backend("die_mid")

      client = Urpc::Client.new("die_mid", timeout: 5)
      # The handler raises IOError which the StreamServer catches, sends :error,
      # then the backend processes it normally.
      e = assert_raises(IOError) { client.call(:die_after_data) }
      assert_equal("backend crashed", e.message)
    end
  end

  def test_backend_death_last_backend_drains_queue
    with_broker do
      # Use a raw socket fake server so we can kill the connection directly.
      # Normal Server/WrapHandler catches handler exceptions and sends a valid :error
      # frame, which doesn't kill the backend connection.
      gate = Queue.new
      fake_server_thread = Thread.new do
        sock = UNIXSocket.open(Urpc.broker_sock)
        sock.write(MessagePack.pack("drain_key"))
        unpacker = MessagePack::DefaultFactory.unpacker(sock)
        # Read the first request
        _request = unpacker.read
        gate.pop # wait for signal
        sock.close # kill the connection — simulates backend death
      end

      raise("fake backend did not register") if !poll_until { @broker.backend_count("drain_key") >= 1 }

      # Submit a call that the fake server will handle (it reads the request but never responds)
      die_thread = Thread.new do
        Urpc::Client.new("drain_key", timeout: 10).call(:work, "die")
      rescue => e
        e
      end

      # Wait for the fake server to read the request
      sleep(0.2)

      # Submit additional calls that will queue up
      error_threads = 3.times.map do
        Thread.new do
          Urpc::Client.new("drain_key", timeout: 10).call(:work, "queued")
        rescue => e
          e
        end
      end

      # Give time for the queued calls to be submitted
      sleep(0.2)

      # Signal the fake server to die
      gate << :go

      # All calls should get errors
      die_result = die_thread.value
      assert_kind_of(Exception, die_result, "die call should get an error")

      results = error_threads.map(&:value)
      results.each do |r|
        assert_kind_of(Exception, r, "expected exception but got #{r.inspect}")
      end

      # Backend should be deregistered
      sleep(0.1)
      assert_equal(0, @broker.backend_count("drain_key"))
    ensure
      fake_server_thread&.kill rescue nil
      die_thread&.kill rescue nil
      error_threads&.each { it.kill rescue nil }
    end
  end

  def test_mid_call_client_disappear_backend_stays
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:slow_work) {|x| sleep(0.5); x }

      start_server("client_gone", handler)
      wait_for_backend("client_gone")

      # Start a stream and immediately close it to simulate client disappear
      client = Urpc::Client.new("client_gone", timeout: 0.1)
      assert_raises(Urpc::TimeoutException) { client.call(:slow_work, "test") }

      # Wait for the server to finish its work
      sleep(0.7)

      # Backend should still be registered
      assert(@broker.backend_count("client_gone") >= 1, "backend should stay registered after client disappears")

      # Subsequent call should succeed
      client2 = Urpc::Client.new("client_gone", timeout: 5)
      assert_equal("ok", client2.call(:slow_work, "ok"))
    end
  end

  def test_server_reconnect_on_broker_restart
    with_broker do
      handler = echo_handler
      _server = start_server("reconnect_key", handler)
      wait_for_backend("reconnect_key")

      # Verify it works
      client = Urpc::Client.new("reconnect_key", timeout: 5)
      assert_equal("hello", client.call(:echo, "hello"))

      # Kill and restart the broker.
      # Don't kill server threads — we want them to reconnect.
      old_broker = @broker
      old_broker.stop
      sleep(0.3)

      @broker = Urpc::Broker.new
      @broker_thread = Thread.new { @broker.run }
      @broker_thread.report_on_exception = false
      wait_for_broker

      # Server should reconnect via its backoff loop
      raise("server did not reconnect") if !poll_until { @broker.backend_count("reconnect_key") >= 1 }

      # Verify it works again
      client2 = Urpc::Client.new("reconnect_key", timeout: 5)
      assert_equal("world", client2.call(:echo, "world"))
    end
  end

  def test_broker_crash_eof_before_terminal
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:slow_thing) {|x| sleep(10); x }

      start_server("broker_crash", handler)
      wait_for_backend("broker_crash")

      # Start a call that will block on the server side
      error = nil
      call_thread = Thread.new do
        Urpc::Client.new("broker_crash", timeout: 5).call(:slow_thing, "test")
      rescue => e
        error = e
      end

      # Wait for the call to be submitted and dispatched
      sleep(0.3)

      # Kill the broker (this closes reply FIFOs)
      @broker.stop

      call_thread.join(5)

      # Client should see either a transport error or BrokerUnavailable
      assert(error, "expected an error when broker crashes")
      assert(
        error.is_a?(Urpc::RemoteException) || error.is_a?(RuntimeError) || error.is_a?(Urpc::BrokerUnavailable) || error.is_a?(Urpc::TimeoutException),
        "expected RemoteException, transport error, BrokerUnavailable, or TimeoutException, got #{error.class}: #{error.message}"
      )
    ensure
      call_thread&.kill rescue nil
    end
  end

  def test_submit_timeout_raises_broker_unavailable
    with_broker do
      # Stop the broker so the submit FIFO has no reader
      @broker.stop
      sleep(0.05)

      # Create a submit FIFO with no reader to trigger timeout
      File.unlink(Urpc.in_fifo) rescue nil
      File.mkfifo(Urpc.in_fifo)
      # Also need broker.sock to exist for preflight
      # The broker.stop already removed it, recreate a dummy
      dummy_sock = UNIXServer.new(Urpc.broker_sock)

      client = Urpc::Client.new("whatever", timeout: 1)
      e = assert_raises(Urpc::BrokerUnavailable) { client.call(:echo, "hi") }
      assert_match(/submit/i, e.message)
    ensure
      dummy_sock&.close rescue nil
    end
  end

  def test_dead_socket_requeues_to_live_backend
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:ping) { |x| sleep(1); x }

      start_server("requeue_key", handler)
      wait_for_backend("requeue_key")

      # Kill server — socket closes but broker backend stays registered with dead socket
      @server_threads.pop.kill rescue nil
      sleep(0.3)

      # Start replacement server — now 1 dead + 1 live backend
      start_server("requeue_key", handler)
      wait_for_backend("requeue_key", count: 2)

      # Concurrent calls — at least one will hit the dead backend
      results = 3.times.map do |i|
        Thread.new { Urpc::Client.new("requeue_key", timeout: 10).call(:ping, i) }
      end.map(&:value)

      assert_equal([0, 1, 2], results.sort)
    end
  end

  def test_dead_socket_requeues_and_waits_for_new_backend
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:ping) { |x| x }

      start_server("requeue_wait_key", handler)
      wait_for_backend("requeue_wait_key")

      # Kill server — stale backend
      @server_threads.pop.kill rescue nil
      sleep(0.3)

      # Send a call - only the dead backend is registered, but this client opts into waiting.
      call_thread = Thread.new do
        Urpc::Client.new("requeue_wait_key", timeout: 10, wait_for_server: true).call(:ping, "delayed")
      end

      sleep(1)

      # Start replacement server — should pick up the re-queued call
      start_server("requeue_wait_key", handler)
      wait_for_backend("requeue_wait_key")

      assert_equal("delayed", call_thread.value)
    end
  end

  def test_dead_socket_requeue_without_wait_for_server_fails_fast
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:ping) { |x| x }

      start_server("requeue_no_wait_key", handler)
      wait_for_backend("requeue_no_wait_key")

      # Kill server - stale backend remains registered until the next dispatch.
      @server_threads.pop.kill rescue nil
      sleep(0.3)

      e = assert_raises(Urpc::NoServerError) do
        Urpc::Client.new("requeue_no_wait_key", timeout: 10).call(:ping, "fail_fast")
      end
      assert_match(/no server registered/, e.message)
    end
  end

  def test_malformed_backend_frame
    with_broker do
      # Create a raw socket server that sends garbage after handshake+request
      fake_server_thread = Thread.new do
        sock = UNIXSocket.open(Urpc.broker_sock)
        sock.write(MessagePack.pack("malformed_backend_key"))

        # Read request frame
        unpacker = MessagePack::DefaultFactory.unpacker(sock)
        _request = unpacker.read

        # Send garbage instead of a valid response frame
        sock.write("\xff\xfe\xfd\xfc\xfb\xfa")
        sleep(1)
        sock.close rescue nil
      end

      raise("fake backend did not register") if !poll_until { @broker.backend_count("malformed_backend_key") >= 1 }

      client = Urpc::Client.new("malformed_backend_key", timeout: 5)
      e = assert_raises { client.call(:whatever) }
      # Should get a RemoteException about backend connection lost
      assert(
        e.is_a?(Urpc::RemoteException) || e.is_a?(RuntimeError),
        "expected RemoteException or RuntimeError, got #{e.class}: #{e.message}"
      )

      # Backend should be deregistered
      sleep(0.2)
      assert_equal(0, @broker.backend_count("malformed_backend_key"))
    ensure
      fake_server_thread&.kill rescue nil
    end
  end

  def test_backend_provided_inbox_response_is_rejected
    with_broker do
      fake_server_thread = Thread.new do
        sock = UNIXSocket.open(Urpc.broker_sock)
        sock.write(MessagePack.pack("backend_inbox_key"))

        unpacker = MessagePack::DefaultFactory.unpacker(sock)
        _request = unpacker.read

        sock.write(Urpc::Frames.pack(:inbox, "/tmp/server-owned-inbox"))
        sleep(1)
        sock.close rescue nil
      end

      raise("fake backend did not register") if !poll_until { @broker.backend_count("backend_inbox_key") >= 1 }

      client = Urpc::Client.new("backend_inbox_key", timeout: 5)
      e = assert_raises(Urpc::RemoteException) { client.call(:whatever) }
      assert_match(/malformed backend frame/, e.message)

      raise("backend was not deregistered") if !poll_until { @broker.backend_count("backend_inbox_key") == 0 }
    ensure
      fake_server_thread&.kill rescue nil
    end
  end
end
