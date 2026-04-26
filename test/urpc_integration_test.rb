# frozen_string_literal: true

require_relative("urpc_test_helper")
require("rbconfig")

class UrpcIntegrationTest < Minitest::Test
  def wait_for_file(path)
    raise("file did not appear: #{path}") if !poll_until { File.exist?(path) }
  end

  def spawn_server(key:, kind:, cast_path: nil)
    ruby = RbConfig.ruby

    code =
      case kind
      when :basic
        <<~RUBY
          require("sfb")
          cast_path = #{cast_path ? cast_path.inspect : "nil"}

          handler = Class.new do
            def initialize(cast_path)
              @cast_path = cast_path
            end

            def echo(x) = x

            def add(a, b) = a + b

            def record(value)
              File.open(@cast_path, "a") { it.puts(value) } if @cast_path
              nil
            end
          end.new(cast_path)

          Urpc::Server.new(#{key.inspect}, handler).run
        RUBY
      when :stream
        <<~RUBY
          require("sfb")

          handler = Class.new do
            def slow_emit(req)
              delay = req.kargs[:delay] || 0.0
              tag = req.args[0]
              req.stream.data([tag, :a])
              sleep(delay)
              req.stream.data([tag, :b])
              req.stream.return([tag, :done])
            end
          end.new

          Urpc::StreamServer.new(#{key.inspect}, handler).run
        RUBY
      else
        raise("unknown server kind: #{kind.inspect}")
      end

    Process.spawn(ruby, "-e", code, out: "/dev/null", err: "/dev/null")
  end

  def test_second_broker_fails_to_start
    with_root do
      broker_pid = spawn_broker
      wait_for_broker

      out = %x(bin/urpc-broker 2>&1)
      assert_match(/already running/, out)
      assert_equal(false, $?.success?)

      # Important: first broker must still be usable.
      assert(File.socket?(Urpc.broker_sock))
      assert(File.pipe?(Urpc.submit_fifo))
      st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
      assert_kind_of(Hash, st)
    end
  end

  def test_multi_process_round_trip
    with_root do
      cast_path = File.join(Urpc.root, "integration_cast.txt")
      File.unlink(cast_path) rescue nil

      broker_pid = spawn_broker
      wait_for_broker

      @server_pid_basic = spawn_server(key: "svc", kind: :basic, cast_path: cast_path)
      @server_pid_a = spawn_server(key: "a", kind: :stream)
      @server_pid_b = spawn_server(key: "b", kind: :stream)

      raise("servers did not register") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:backends]["svc"].to_i >= 1 && st[:backends]["a"].to_i >= 1 && st[:backends]["b"].to_i >= 1
      end

      client = Urpc::Client.new("svc", timeout: 5)
      assert_equal("hello", client.call(:echo, "hello"))
      assert_equal(7, client.call(:add, 3, 4))

      assert_nil(client.cast(:record, "cast-1"))
      wait_for_file(cast_path)
      assert_includes(File.read(cast_path), "cast-1")

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

      st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
      assert(st[:backends]["svc"].to_i >= 1)
      assert(st[:queue_depths]["svc"].to_i >= 0)
      assert(st[:in_flight]["svc"].to_i >= 0)
    ensure
      s1&.close rescue nil
      s2&.close rescue nil
    end
  end

  def test_broker_sigterm_exits_and_leaves_sane_tmp_state
    with_root do
      broker_pid = spawn_broker
      wait_for_broker

      reqs_dir = Urpc.requests_dir
      reps_dir = Urpc.replies_dir

      Process.kill("TERM", broker_pid)
      Process.wait(broker_pid)

      refute(File.exist?(Urpc.broker_sock))
      refute(File.exist?(Urpc.submit_fifo))

      assert(File.directory?(reqs_dir))
      assert(File.directory?(reps_dir))
      assert_empty(Dir.children(reqs_dir))
      assert_empty(Dir.children(reps_dir))
    ensure
      teardown_process(broker_pid)
    end
  end
end
