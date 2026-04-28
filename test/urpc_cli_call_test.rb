# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcCliCallTest < Minitest::Test
  def assert_parse_cli(input, expected)
    assert_equal(expected, Urpc::CliCall.parse_cli(input))
  end

  def assert_parse_ruby(input, expected)
    assert_equal(expected, Urpc::CliCall.parse_ruby(input))
  end

  def assert_cli_ok(*)
    out, ok = run_cli_call(*)
    assert(ok, "cli failed: #{out}")
    out
  end

  def test_parse_cli_method_only
    assert_parse_cli(["status"], name: :status, args: [], kargs: {})
  end

  def test_parse_cli_positional_args
    assert_parse_cli(%w[lookup user123], name: :lookup, args: ["user123"], kargs: {})
  end

  def test_parse_cli_auto_types_integers
    assert_parse_cli(%w[add 1 2], name: :add, args: [1, 2], kargs: {})
  end

  def test_parse_cli_auto_types_floats
    assert_parse_cli(["div", "3.14"], name: :div, args: [3.14], kargs: {})
  end

  def test_parse_cli_auto_types_bool_and_nil
    assert_parse_cli(%w[f true false nil], name: :f, args: [true, false, nil], kargs: {})
  end

  def test_parse_cli_kwargs
    assert_parse_cli(["search", "hi", "limit=10"], name: :search, args: ["hi"], kargs: { limit: 10 })
  end

  def test_parse_cli_multiple_kwargs
    assert_parse_cli(["f", "limit=10", "active=true", "ratio=3.14", "name=alice"],
      name: :f, args: [], kargs: { limit: 10, active: true, ratio: 3.14, name: "alice" })
  end

  def test_parse_cli_mixed_positional_and_kwargs
    assert_parse_cli(["search", "hello", "limit=5", "verbose=true"],
      name: :search, args: ["hello"], kargs: { limit: 5, verbose: true })
  end

  def test_parse_cli_negative_integer
    assert_parse_cli(["f", "-3"], name: :f, args: [-3], kargs: {})
  end

  def test_parse_cli_negative_float
    assert_parse_cli(["f", "-1.5"], name: :f, args: [-1.5], kargs: {})
  end

  def test_parse_cli_negative_integer_kwarg
    assert_parse_cli(["f", "offset=-10"], name: :f, args: [], kargs: { offset: -10 })
  end

  def test_parse_cli_string_that_looks_like_number_is_not
    assert_parse_cli(%w[f 123abc], name: :f, args: ["123abc"], kargs: {})
  end

  def test_parse_cli_empty_args_raises
    assert_raises(Urpc::CliCall::Error) { Urpc::CliCall.parse_cli([]) }
  end

  def test_parse_cli_kwarg_string_value
    assert_parse_cli(["f", "name=alice"], name: :f, args: [], kargs: { name: "alice" })
  end

  def test_parse_ruby_method_only
    assert_parse_ruby("status", name: :status, args: [], kargs: {})
  end

  def test_parse_ruby_string_arg
    assert_parse_ruby('lookup("user123")', name: :lookup, args: ["user123"], kargs: {})
  end

  def test_parse_ruby_integer_and_float
    assert_parse_ruby("add(1, 2.5)", name: :add, args: [1, 2.5], kargs: {})
  end

  def test_parse_ruby_symbol
    assert_parse_ruby("f(:hello)", name: :f, args: [:hello], kargs: {})
  end

  def test_parse_ruby_bool_and_nil
    assert_parse_ruby("f(true, false, nil)", name: :f, args: [true, false, nil], kargs: {})
  end

  def test_parse_ruby_kwargs
    assert_parse_ruby('search("hi", limit: 10)', name: :search, args: ["hi"], kargs: { limit: 10 })
  end

  def test_parse_ruby_array_arg
    assert_parse_ruby("f([1, :two, \"three\"])", name: :f, args: [[1, :two, "three"]], kargs: {})
  end

  def test_parse_ruby_hash_arg
    assert_parse_ruby('f({ :a => 1, "b" => 2 })', name: :f, args: [{ a: 1, "b" => 2 }], kargs: {})
  end

  def test_parse_ruby_complex_kwargs
    assert_parse_ruby('f(three: { :four => [:five, 5], "six" => ["seven"] })',
      name: :f, args: [], kargs: { three: { four: [:five, 5], "six" => ["seven"] } })
  end

  def test_parse_ruby_pathological
    assert_parse_ruby('pathological(:one, "two", 2, :"2", "2", three: { :four => [:five, 5], "six" => ["seven"] })',
      name: :pathological, args: [:one, "two", 2, :"2", "2"],
      kargs: { three: { four: [:five, 5], "six" => ["seven"] } })
  end

  def test_parse_ruby_syntax_error_raises
    assert_raises(Urpc::CliCall::Error) { Urpc::CliCall.parse_ruby("f(") }
  end

  def test_parse_ruby_non_call_raises
    assert_raises(Urpc::CliCall::Error) { Urpc::CliCall.parse_ruby("42") }
  end

  def test_parse_ruby_unsupported_node_raises
    assert_raises(Urpc::CliCall::Error) { Urpc::CliCall.parse_ruby("f(1..10)") }
  end

  def spawn_echo_server(key, cast_path: nil)
    ruby = RbConfig.ruby
    code = <<~RUBY
      require("sfb")
      cast_path = #{cast_path ? cast_path.inspect : "nil"}

      handler = Class.new do
        def initialize(cast_path)
          @cast_path = cast_path
        end

        def echo_args(*args, **kargs)
          { args: args, kargs: kargs }
        end

        def record(value)
          File.open(@cast_path, "a") { it.puts(value) } if @cast_path
          nil
        end
      end.new(cast_path)
      Urpc::Server.new(#{key.inspect}, handler).run
    RUBY
    Process.spawn(ruby, "-e", code, out: "/dev/null", err: "/dev/null")
  end

  def spawn_stream_server(key)
    ruby = RbConfig.ruby
    code = <<~RUBY
      require("sfb")

      handler = Class.new do
        def slow_emit(req)
          tag = req.args[0]
          req.stream.data("\#{tag}-a")
          req.stream.data("\#{tag}-b")
          req.stream.return("\#{tag}-done")
        end
      end.new
      Urpc::StreamServer.new(#{key.inspect}, handler).run
    RUBY
    Process.spawn(ruby, "-e", code, out: "/dev/null", err: "/dev/null")
  end

  def wait_for_file(path)
    raise("file did not appear: #{path}") if !poll_until { File.exist?(path) }
  end

  def run_cli_call(*args)
    bin = File.expand_path("../bin/urpc-call", __dir__)
    out = %x(#{bin} #{Shellwords.join(args)} 2>&1)
    [out, $?.success?]
  end

  def test_cli_call_round_trip
    with_root do
      broker_pid = spawn_broker
      wait_for_broker
      cast_path = File.join(Urpc.root, "cast.txt")
      server_pid = spawn_echo_server("svc", cast_path: cast_path)
      raise("server did not register") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:backends]["svc"].to_i >= 1
      end

      assert_includes(assert_cli_ok("svc", "echo_args", "hello"), "hello")
      assert_includes(assert_cli_ok("svc", "echo_args", "1", "2"), "args: [1, 2]")
      assert_includes(assert_cli_ok("svc", "echo_args", "limit=10"), "limit: 10")
      assert_includes(assert_cli_ok("svc", "echo_args", "active=true"), "active: true")

      out = assert_cli_ok("svc", 'echo_args("hi", limit: 10)')
      assert_includes(out, "args: [\"hi\"]")
      assert_includes(out, "limit: 10")

      out = assert_cli_ok("-f", "json", "svc", "echo_args", "x")
      assert_equal(["x"], JSON.parse(out)["args"])

      assert_cli_ok("--cast", "svc", "record", "cast-1")
      wait_for_file(cast_path)
      assert_includes(File.read(cast_path), "cast-1")

      out, ok = run_cli_call("svc", "nonexistent")
      refute(ok, "expected failure for missing method")
      assert_match(/Error:/, out)
    ensure
      teardown_process(server_pid)
      teardown_process(broker_pid)
    end
  end

  def test_cli_call_stream
    with_root do
      broker_pid = spawn_broker
      wait_for_broker
      stream_pid = spawn_stream_server("svc")
      raise("server did not register") if !poll_until do
        st = Urpc::Client.new("urpc", timeout: 1).call(:stats)
        st[:backends]["svc"].to_i >= 1
      end

      out = assert_cli_ok("--stream", "svc", "slow_emit", "X")

      assert_includes(out, 'data: "X-a"')
      assert_includes(out, 'data: "X-b"')
      assert_includes(out, 'return: "X-done"')
    ensure
      teardown_process(stream_pid)
      teardown_process(broker_pid)
    end
  end

  def test_cli_call_cast_and_stream_conflict
    out, ok = run_cli_call("--cast", "--stream", "svc", "f")
    refute(ok)
    assert_match(/mutually exclusive/, out)
  end

  def test_parse_cli_dot_float_forms
    assert_parse_cli(["f", "1.", ".5"], name: :f, args: [1.0, 0.5], kargs: {})
  end
end
