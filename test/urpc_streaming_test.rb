# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcStreamingTest < Minitest::Test
  def emitter_handler
    Class.new do
      def emit_three(req)
        req.stream.data(1)
        req.stream.data(2)
        req.stream.return(3)
      end

      def slow_emit(req)
        delay = req.kargs[:delay] || 0.0
        tag = req.args[0]
        req.stream.data([tag, :a])
        sleep(delay)
        req.stream.data([tag, :b])
        req.stream.return([tag, :done])
      end
    end.new
  end

  def echo_handler
    Class.new do
      def echo(x) = x
      def add(a, b) = a + b
      def boom = raise(ArgumentError, "kaboom")
      def slow(ms) = (sleep(ms / 1000.0); "slow-done")
    end.new
  end

  def test_next_event_ignores_finished_stream
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:foo) { "ok" }
      start_server("finished_stream", handler)
      wait_for_backend("finished_stream")
      client = Urpc::Client.new("finished_stream")
      s = client.stream(:foo)
      s.close
      assert_nil(client.next_event(s))
    end
  end

  def test_streaming_round_trip_with_data_events
    with_broker do
      start_stream_server("emit", emitter_handler)
      wait_for_backend("emit")

      client = Urpc::Client.new("emit", timeout: 5)
      s = client.stream(:emit_three)
      events = []
      s.each_event {|e| events << [e.type, e.data] }
      assert_equal([[:data, 1], [:data, 2], [:return, 3]], events)
      assert(s.finished?)
      assert_equal(3, s.result_value)
    end
  end

  def test_event_stream_result_returns_terminal_value
    with_broker do
      start_server("echo", echo_handler)
      wait_for_backend("echo")

      client = Urpc::Client.new("echo", timeout: 5)
      s = client.stream(:echo, "yo")
      assert_equal("yo", s.result)
      assert(s.finished?)
    end
  end

  def test_event_stream_result_re_raises_hydrated_error
    with_broker do
      start_server("echo", echo_handler)
      wait_for_backend("echo")

      client = Urpc::Client.new("echo", timeout: 5)
      s = client.stream(:boom)
      e = assert_raises(ArgumentError) { s.result }
      assert_equal("kaboom", e.message)
    end
  end

  def test_cast_records_call
    with_broker do
      q = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:record) {|value| q << value; nil }
      start_server("rec", handler)
      wait_for_backend("rec")

      client = Urpc::Client.new("rec", timeout: 5)
      assert_nil(client.cast(:record, "hello"))

      raise("cast did not arrive") if !poll_until { !q.empty? }
      assert_equal("hello", q.pop)
    end
  end

  def test_cast_with_no_backend_drops_silently
    with_broker do
      client = Urpc::Client.new("nope_cast", timeout: 5)
      assert_nil(client.cast(:whatever, 1, 2))
      sleep(0.05)
      assert_equal(0, @broker.backend_count("nope_cast"))
    end
  end

  def test_call_with_no_backend_raises_no_server_error
    with_broker do
      client = Urpc::Client.new("nope_call", timeout: 5)
      assert_raises(Urpc::NoServerError) { client.call(:whatever) }
    end
  end

  def test_multiplex_each_event_interleaves_streams
    with_broker do
      start_stream_server("a", emitter_handler)
      start_stream_server("b", emitter_handler)
      wait_for_backend("a")
      wait_for_backend("b")

      client_a = Urpc::Client.new("a", timeout: 5)
      client_b = Urpc::Client.new("b", timeout: 5)

      s1 = client_a.stream(:slow_emit, "A", delay: 0.05)
      s2 = client_b.stream(:slow_emit, "B", delay: 0.0)

      events = []
      client_a.each_event(s1, s2) {|s, e| events << [s.equal?(s1) ? :s1 : :s2, e.type, e.data] }

      s1_events = events.select {|s, _, _| s == :s1 }
      s2_events = events.select {|s, _, _| s == :s2 }
      assert_equal([[:s1, :data, ["A", :a]], [:s1, :data, ["A", :b]], [:s1, :return, ["A", :done]]], s1_events)
      assert_equal([[:s2, :data, ["B", :a]], [:s2, :data, ["B", :b]], [:s2, :return, ["B", :done]]], s2_events)
      assert(s1.finished?)
      assert(s2.finished?)
    end
  end

  def test_next_event_returns_pair_and_marks_finished
    with_broker do
      start_server("ne", echo_handler)
      wait_for_backend("ne")

      client = Urpc::Client.new("ne", timeout: 5)
      s = client.stream(:echo, "hi")
      pair = client.next_event(s)
      refute_nil(pair)
      ret_stream, event = pair
      assert_same(s, ret_stream)
      assert_equal(:return, event.type)
      assert_equal("hi", event.data)
      assert(s.finished?)
      assert_nil(client.next_event(s))
    end
  end

  def test_next_event_streams_data_then_return
    with_broker do
      start_stream_server("emit2", emitter_handler)
      wait_for_backend("emit2")

      client = Urpc::Client.new("emit2", timeout: 5)
      s = client.stream(:emit_three)

      _, e1 = client.next_event(s)
      assert_equal([:data, 1], [e1.type, e1.data])
      refute(s.finished?)

      _, e2 = client.next_event(s)
      assert_equal([:data, 2], [e2.type, e2.data])
      refute(s.finished?)

      _, e3 = client.next_event(s)
      assert_equal([:return, 3], [e3.type, e3.data])
      assert(s.finished?)
    end
  end

  def test_method_missing_round_trip
    with_broker do
      start_server("mm", echo_handler)
      wait_for_backend("mm")

      client = Urpc::Client.new("mm", timeout: 5)
      assert_equal(7, client.add(3, 4))
      assert_equal("hi", client.echo("hi"))
    end
  end

  def test_respond_to_missing_round_trip
    with_broker do
      start_server("rtm", echo_handler)
      wait_for_backend("rtm")

      client = Urpc::Client.new("rtm", timeout: 5)
      assert(client.respond_to?(:add))
      assert(client.respond_to?(:echo))
      refute(client.respond_to?(:nonexistent_method))
    end
  end

  def test_def_stream_to_basic_exposes_stream_method
    with_broker do
      klass = Class.new
      Urpc::Util.def_stream_to_basic(klass, :double) {|x| x * 2 }
      Urpc::Util.def_stream_to_basic(klass, :greet) {|name:| "hi #{name}" }
      handler = klass.new

      start_stream_server("ds", handler)
      wait_for_backend("ds")

      client = Urpc::Client.new("ds", timeout: 5)
      assert_equal(42, client.call(:double, 21))
      assert_equal("hi alice", client.call(:greet, name: "alice"))
    end
  end

  def test_default_timeout_zero_blocks_normally
    with_broker do
      start_server("delay", echo_handler)
      wait_for_backend("delay")

      client = Urpc::Client.new("delay")
      assert_equal(0, client.timeout)
      assert_equal("slow-done", client.call(:slow, 200))
    end
  end
end
