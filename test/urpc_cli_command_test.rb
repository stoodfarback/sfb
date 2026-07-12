# frozen_string_literal: true

require_relative("test_helper")

class UrpcCliCommandTest < Minitest::Test
  class Help < Urpc::CliCommand
    def perform!
      stdout("performed\n")
      5
    end
  end

  class UsageError < Urpc::CliCommand
    def help_text
      "Usage: usage VALUE\n"
    end

    def validate!
      raise(ArgumentError, "value is required")
    end

    def perform!
      raise("validation must stop the command body")
    end
  end

  class Output < Urpc::CliCommand
    def perform!
      stdout("out\n")
      stderr("err\n")
      7
    end
  end

  class CallerOperations < Urpc::CliCommand
    def perform!
      values = [
        caller_cwd,
        glob("*.txt"),
        read_file_binary("data.bin"),
        read_file_utf8("data.txt"),
        list_dir("."),
        path_info("data.txt"),
        read_env("NAME"),
        list_env,
        list_env(include_values: true),
        read_stdin,
        stdin_tty?,
        stdout_tty?,
        stderr_tty?,
      ]
      stdout(values.inspect)
      nil
    end
  end

  class WaitForCancel < Urpc::CliCommand
    def perform!
      stdout("started\n")
      sleep(0.001) until cancelled?
      stdout("cancelled\n")
      130
    end
  end

  class InvalidStatus < Urpc::CliCommand
    def perform!
      256
    end
  end

  class CommandBug < Urpc::CliCommand
    def perform!
      raise(ArgumentError, "command bug")
    end
  end

  class WaitForControl < Urpc::CliCommand
    def perform!
      stdout("started\n")
      sleep(0.001) until finished?
      0
    end
  end

  class NestedChild < Urpc::CliCommand
    attr_accessor(:prefix)

    def initialize(prefix:, **command_kargs)
      super(**command_kargs)
      self.prefix = prefix
    end

    def perform!
      stdout("#{prefix}|#{command_name}|#{caller_cwd}|#{read_env("NAME")}|#{argv.join(",")}\n")
      9
    end
  end

  class NestedRoot < Urpc::CliCommand
    def perform!
      name, *child_argv = argv
      command_class = name == "cancel" ? WaitForCancel : NestedChild
      command_kargs = command_class == NestedChild ? { prefix: "nested" } : {}

      run_subcommand(command_class, command_name: "tool #{name}", argv: child_argv, **command_kargs)
    end
  end

  def test_help_uses_requested_command_name_and_skips_command_body
    with_cli_server(help: Help) do |client|
      stream = cli_stream(client, :help, argv: ["--help"])

      assert_equal([{ type: :stdout, data: "Usage: help\n" }], stream.to_a)
      assert_equal(0, stream.result)

      literal_stream = cli_stream(client, :help, argv: ["value", "--help"])
      assert_equal([{ type: :stdout, data: "performed\n" }], literal_stream.to_a)
      assert_equal(5, literal_stream.result)
    end
  end

  def test_usage_errors_stream_message_and_help_with_status_two
    with_cli_server(usage: UsageError) do |client|
      stream = cli_stream(client, :usage)

      assert_equal([
        { type: :stderr, data: "value is required\n\n" },
        { type: :stderr, data: "Usage: usage VALUE\n" },
      ], stream.to_a)
      assert_equal(2, stream.result)
    end
  end

  def test_streams_stdout_and_stderr_and_returns_status
    with_cli_server(output: Output) do |client|
      stream = cli_stream(client, :output)

      assert_equal([
        { type: :stdout, data: "out\n" },
        { type: :stderr, data: "err\n" },
      ], stream.to_a)
      assert_equal(7, stream.result)
    end
  end

  def test_caller_side_helpers_use_the_cli_operation_protocol
    with_cli_server(operations: CallerOperations) do |client|
      stream = cli_stream(client, :operations)
      events = stream.each
      exchanges = [
        [{ type: :op, op: :glob, pattern: "*.txt" }, ["a.txt"]],
        [{ type: :op, op: :read_file_binary, path: "data.bin" }, "binary".b],
        [{ type: :op, op: :read_file_utf8, path: "data.txt" }, "text"],
        [{ type: :op, op: :list_dir, path: "." }, [{ name: "data.txt" }]],
        [{ type: :op, op: :path_info, path: "data.txt" }, { exists: true, file: true }],
        [{ type: :op, op: :read_env, name: "NAME" }, "value"],
        [{ type: :op, op: :list_env }, ["NAME"]],
        [{ type: :op, op: :list_env, include_values: true }, { "NAME" => "value" }],
        [{ type: :op, op: :read_stdin }, "stdin"],
        [{ type: :op, op: :stdin_tty }, false],
        [{ type: :op, op: :stdout_tty }, true],
        [{ type: :op, op: :stderr_tty }, false],
      ]

      exchanges.each do |event, value|
        assert_equal(event, events.next)
        stream.send_sync(type: :op_result, ok: true, value:)
      end

      values = ["/workspace", *exchanges.map(&:last)]
      assert_equal({ type: :stdout, data: values.inspect }, events.next)
      assert_raises(StopIteration) { events.next }
      assert_equal(0, stream.result)
    end
  end

  def test_malformed_caller_operation_result_becomes_a_remote_error
    with_cli_server(operations: CallerOperations) do |client|
      stream = cli_stream(client, :operations)
      events = stream.each

      assert_equal({ type: :op, op: :glob, pattern: "*.txt" }, events.next)
      stream.send_sync(type: :wrong)

      error = assert_raises(RuntimeError) { stream.result }
      assert_equal("malformed cli operation result", error.message)
    end
  end

  def test_async_cancel_and_input_disconnect_mark_the_command_cancelled
    with_cli_server(cancel: WaitForCancel) do |client|
      async_stream = cli_stream(client, :cancel)
      async_events = async_stream.each
      assert_equal({ type: :stdout, data: "started\n" }, async_events.next)
      async_stream.send_async(type: :cancel)
      assert_equal({ type: :stdout, data: "cancelled\n" }, async_events.next)
      assert_equal(130, async_stream.result)

      disconnect_stream = cli_stream(client, :cancel)
      disconnect_events = disconnect_stream.each
      assert_equal({ type: :stdout, data: "started\n" }, disconnect_events.next)
      disconnect_stream.close_input
      assert_equal({ type: :stdout, data: "cancelled\n" }, disconnect_events.next)
      assert_equal(130, disconnect_stream.result)
    end
  end

  def test_rejects_invalid_invocations
    with_cli_server(output: Output) do |client|
      error = assert_raises(ArgumentError) { client.bidirectional(:output, argv: [:bad], caller_cwd: "/workspace").result }
      assert_equal("cli argv must be an Array of String", error.message)

      error = assert_raises(ArgumentError) { client.bidirectional(:output, argv: [], caller_cwd: "").result }
      assert_equal("cli caller_cwd must be a non-empty String", error.message)

      assert_raises(ArgumentError) { client.bidirectional(:output, argv: []).result }
      assert_raises(ArgumentError) { client.bidirectional(:output, argv: [], caller_cwd: "/workspace", extra: true).result }
      assert_raises(ArgumentError) { client.bidirectional(:output, { argv: [], caller_cwd: "/workspace" }).result }
    end
  end

  def test_rejects_invalid_exit_status
    with_cli_server(invalid_status: InvalidStatus) do |client|
      error = assert_raises(RuntimeError) { cli_stream(client, :invalid_status).result }

      assert_equal("invalid cli status: 256", error.message)
    end
  end

  def test_argument_error_from_command_execution_is_not_presented_as_usage
    with_cli_server(bug: CommandBug) do |client|
      stream = cli_stream(client, :bug)

      error = assert_raises(ArgumentError) { stream.result }
      assert_equal("command bug", error.message)
    end
  end

  def test_rejects_unknown_async_control_messages
    with_cli_server(control: WaitForControl) do |client|
      stream = cli_stream(client, :control)
      events = stream.each

      assert_equal({ type: :stdout, data: "started\n" }, events.next)
      stream.send_async(type: :pause)

      error = assert_raises(ArgumentError) { stream.result }
      assert_equal("unsupported cli async input: {type: :pause}", error.message)
    end
  end

  def test_nested_command_uses_full_lifecycle_and_shared_session
    with_cli_server(nested: NestedRoot) do |client|
      help_stream = cli_stream(client, :nested, argv: ["child", "--help"])
      assert_equal([{ type: :stdout, data: "Usage: tool child\n" }], help_stream.to_a)
      assert_equal(0, help_stream.result)

      stream = cli_stream(client, :nested, argv: ["child", "one", "two"])
      events = stream.each
      assert_equal({ type: :op, op: :read_env, name: "NAME" }, events.next)
      stream.send_sync(type: :op_result, ok: true, value: "value")
      assert_equal({ type: :stdout, data: "nested|tool child|/workspace|value|one,two\n" }, events.next)
      assert_raises(StopIteration) { events.next }
      assert_equal(9, stream.result)
    end
  end

  def test_nested_command_observes_session_cancellation
    with_cli_server(nested: NestedRoot) do |client|
      stream = cli_stream(client, :nested, argv: ["cancel"])
      events = stream.each
      assert_equal({ type: :stdout, data: "started\n" }, events.next)

      stream.send_async(type: :cancel)

      assert_equal({ type: :stdout, data: "cancelled\n" }, events.next)
      assert_equal(130, stream.result)
    end
  end

  def cli_stream(client, name, argv: [], caller_cwd: "/workspace")
    client.bidirectional(name, argv:, caller_cwd:)
  end

  def with_cli_server(**commands)
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(**commands)
      server = Urpc::Server.new("svc", &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 2)

      yield(client)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end
end
