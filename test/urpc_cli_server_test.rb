# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcCliServerTest < Minitest::Test
  class HelpCommand < Urpc::CliCommand
    def help_text
      "Usage: help_cmd\n"
    end

    def perform!
      stdout("performed\n")
      5
    end
  end

  class ValidateCommand < Urpc::CliCommand
    def help_text
      "Usage: validate_cmd VALUE\n"
    end

    def validate!
      raise(ArgumentError, "validation failed")
    end

    def perform!
      stdout("should not run\n")
      0
    end
  end

  class StreamCommand < Urpc::CliCommand
    def perform!
      stdout("out\n")
      stderr("err\n")
      7
    end
  end

  class WorkspaceCommand < Urpc::CliCommand
    def perform!
      payload = {
        argv: argv,
        cwd: cwd,
        paths: glob("*.txt").sort,
        file: read_file("alpha.txt"),
        dir: list_dir("."),
        env_one: read_env("URPC_CLI_TEST_ENV"),
        env_names_has_key: list_env.include?("URPC_CLI_TEST_ENV"),
        env_value: list_env(include_values: true)["URPC_CLI_TEST_ENV"],
        stdin: read_stdin,
        stdin_again: read_stdin,
      }
      stdout(JSON.generate(payload))
      0
    end
  end

  class PathInfoCommand < Urpc::CliCommand
    def perform!
      payload = argv.to_h { [it, path_info(it)] }
      stdout(JSON.generate(payload))
      0
    end
  end

  class TtyCommand < Urpc::CliCommand
    def perform!
      payload = {
        stdin_tty: stdin_tty?,
        stdout_tty: stdout_tty?,
        stderr_tty: stderr_tty?,
      }
      stdout(JSON.generate(payload))
      0
    end
  end

  class UnsupportedOpCommand < Urpc::CliCommand
    def perform!
      client_op(op: :read_socket)
      0
    end
  end

  class MalformedEventCommand < Urpc::CliCommand
    def perform!
      data("not a cli event")
      0
    end
  end

  class CancelCommand < Urpc::CliCommand
    def perform!
      stdout("started\n")
      loop do
        break if cancelled?
        sleep(0.01)
      end
      stdout("cancelled\n")
      130
    end
  end

  class IgnoreCancelStreamCommand < Urpc::CliCommand
    def perform!
      stdout("started\n")
      loop do
        stdout("still-running\n")
        sleep(0.01)
      end
    end
  end

  class Handler
    def help_cmd(req)
      req.handle_bidirectional!(HelpCommand, command_name: __method__)
    end

    def validate_cmd(req)
      req.handle_bidirectional!(ValidateCommand, command_name: __method__)
    end

    def stream_cmd(req)
      req.handle_bidirectional!(StreamCommand, command_name: __method__)
    end

    def workspace_cmd(req)
      req.handle_bidirectional!(WorkspaceCommand, command_name: __method__)
    end

    def path_info_cmd(req)
      req.handle_bidirectional!(PathInfoCommand, command_name: __method__)
    end

    def tty_cmd(req)
      req.handle_bidirectional!(TtyCommand, command_name: __method__)
    end

    def unsupported_op_cmd(req)
      req.handle_bidirectional!(UnsupportedOpCommand, command_name: __method__)
    end

    def malformed_event_cmd(req)
      req.handle_bidirectional!(MalformedEventCommand, command_name: __method__)
    end

    def cancel_cmd(req)
      req.handle_bidirectional!(CancelCommand, command_name: __method__)
    end

    def ignore_cancel_stream_cmd(req)
      req.handle_bidirectional!(IgnoreCancelStreamCommand, command_name: __method__)
    end
  end

  def start_cli_server
    key = "cli_server_test"
    start_stream_server(key, Handler.new)
    wait_for_backend(key)
    key
  end

  def call_cli(*, chdir: nil, stdin_data: "", env: {})
    bin = File.expand_path("../bin/urpc-call-cli", __dir__)
    options = { stdin_data: stdin_data }
    options[:chdir] = chdir if chdir
    Open3.capture3({ "URPC_ROOT" => Urpc.root }.merge(env), bin, *, **options)
  end

  def test_help_is_owned_by_server_command
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "help_cmd", "--help")

      assert(status.success?, stderr)
      assert_equal("Usage: help_cmd\n", stdout)
      assert_equal("", stderr)
    end
  end

  def test_validation_error_streams_usage_and_exits_two
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "validate_cmd", "x")

      assert_equal(2, status.exitstatus)
      assert_equal("", stdout)
      assert_includes(stderr, "validation failed")
      assert_includes(stderr, "Usage: validate_cmd VALUE")
    end
  end

  def test_stdout_stderr_and_status_are_forwarded
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "stream_cmd")

      assert_equal(7, status.exitstatus)
      assert_equal("out\n", stdout)
      assert_equal("err\n", stderr)
    end
  end

  def test_caller_side_operations_use_invocation_workspace
    with_broker do
      key = start_cli_server

      Dir.mktmpdir("urpc-cli-workspace-") do |workspace|
        File.write(File.join(workspace, "alpha.txt"), "alpha-data")
        File.write(File.join(workspace, "beta.txt"), "beta-data")
        Dir.mkdir(File.join(workspace, "nested"))

        stdout, stderr, status = call_cli(
          key,
          "workspace_cmd",
          "arg1",
          "--server-flag",
          chdir: workspace,
          stdin_data: "stdin-data",
          env: { "URPC_CLI_TEST_ENV" => "env-value" },
        )

        assert(status.success?, stderr)
        data = JSON.parse(stdout)
        dir_by_name = data["dir"].to_h { [it["name"], it] }

        assert_equal(["arg1", "--server-flag"], data["argv"])
        assert_equal(workspace, data["cwd"])
        assert_equal(["alpha.txt", "beta.txt"], data["paths"])
        assert_equal("alpha-data", data["file"])
        assert_equal("file", dir_by_name["alpha.txt"]["type"])
        assert_equal("dir", dir_by_name["nested"]["type"])
        assert_equal("env-value", data["env_one"])
        assert_equal(true, data["env_names_has_key"])
        assert_equal("env-value", data["env_value"])
        assert_equal("stdin-data", data["stdin"])
        assert_equal("", data["stdin_again"])
      end
    end
  end

  def test_path_info_reports_caller_side_path_metadata
    with_broker do
      key = start_cli_server

      Dir.mktmpdir("urpc-cli-path-info-") do |workspace|
        File.write(File.join(workspace, "regular.txt"), "data")
        Dir.mkdir(File.join(workspace, "subdir"))
        File.symlink("regular.txt", File.join(workspace, "link_to_file"))
        File.symlink("subdir", File.join(workspace, "link_to_dir"))
        File.symlink("nope", File.join(workspace, "broken_link"))

        stdout, stderr, status = call_cli(
          key,
          "path_info_cmd",
          "missing",
          "regular.txt",
          "subdir",
          "link_to_file",
          "link_to_dir",
          "broken_link",
          chdir: workspace,
        )

        assert(status.success?, stderr)
        data = JSON.parse(stdout)

        assert_equal({ "exists" => false, "file" => false, "directory" => false, "symlink" => false }, data["missing"])
        assert_equal({ "exists" => true, "file" => true, "directory" => false, "symlink" => false }, data["regular.txt"])
        assert_equal({ "exists" => true, "file" => false, "directory" => true, "symlink" => false }, data["subdir"])
        assert_equal({ "exists" => true, "file" => true, "directory" => false, "symlink" => true }, data["link_to_file"])
        assert_equal({ "exists" => true, "file" => false, "directory" => true, "symlink" => true }, data["link_to_dir"])
        assert_equal({ "exists" => false, "file" => false, "directory" => false, "symlink" => true }, data["broken_link"])
      end
    end
  end

  def test_request_shape_is_validated
    with_broker do
      key = start_cli_server

      stream = Urpc::Client.new(key, timeout: 5).bidirectional_stream(:stream_cmd, {
        version: 2,
        argv: [],
        cwd: Dir.pwd,
      })

      e = assert_raises(ArgumentError) { stream.result }
      assert_match(/unsupported cli protocol version/, e.message)
    end
  end

  def test_tty_helpers_report_piped_stdio_false
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "tty_cmd")

      assert(status.success?, stderr)
      assert_equal("", stderr)
      data = JSON.parse(stdout)
      assert_equal(false, data["stdin_tty"])
      assert_equal(false, data["stdout_tty"])
      assert_equal(false, data["stderr_tty"])
    end
  end

  def test_tty_client_operations_report_closed_stdio_false
    old_stdin = $stdin
    old_stdout = $stdout
    old_stderr = $stderr
    $stdin = closed_io
    $stdout = closed_io
    $stderr = closed_io

    client = Urpc::CliClient.new([])
    assert_equal(false, client.operation_value(op: :stdin_tty))
    assert_equal(false, client.operation_value(op: :stdout_tty))
    assert_equal(false, client.operation_value(op: :stderr_tty))
  ensure
    $stdin = old_stdin
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def closed_io
    read, write = IO.pipe
    read.close
    write.close
    read
  end

  def test_unsupported_client_operation_returns_remote_error
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "unsupported_op_cmd")

      refute(status.success?)
      assert_equal("", stdout)
      assert_match(/unsupported cli op: read_socket/, stderr)
    end
  end

  def test_malformed_cli_event_fails_client_protocol
    with_broker do
      key = start_cli_server

      stdout, stderr, status = call_cli(key, "malformed_event_cmd")

      refute(status.success?)
      assert_equal("", stdout)
      assert_match(/malformed cli event/, stderr)
    end
  end

  def test_ctrl_c_sends_async_cancel
    with_broker do
      key = start_cli_server
      bin = File.expand_path("../bin/urpc-call-cli", __dir__)

      Open3.popen3({ "URPC_ROOT" => Urpc.root }, bin, key, "cancel_cmd") do |stdin, stdout, stderr, wait_thread|
        stdin.close
        assert(stdout.wait_readable(5), "cancel command did not start")
        assert_equal("started\n", stdout.gets)

        Process.kill("INT", wait_thread.pid)
        joined = wait_thread.join(5)
        Process.kill("TERM", wait_thread.pid) if !joined
        assert(joined, "cancel command did not exit")

        assert_includes(stdout.read, "cancelled\n")
        assert_equal("", stderr.read)
        assert_equal(130, wait_thread.value.exitstatus)
      end
    end
  end

  def test_second_ctrl_c_force_quits_even_while_server_streams
    with_broker do
      key = start_cli_server
      bin = File.expand_path("../bin/urpc-call-cli", __dir__)

      Open3.popen3({ "URPC_ROOT" => Urpc.root }, bin, key, "ignore_cancel_stream_cmd") do |stdin, stdout, stderr, wait_thread|
        stdin.close
        assert(stdout.wait_readable(5), "streaming command did not start")
        assert_equal("started\n", stdout.gets)
        stderr_reader = Thread.new { stderr.read }
        stdout_reader = Thread.new { stdout.read }

        Process.kill("INT", wait_thread.pid)
        sleep(0.1)
        Process.kill("INT", wait_thread.pid)

        joined = wait_thread.join(3)
        Process.kill("TERM", wait_thread.pid) if !joined
        assert(joined, "client did not force quit after second Ctrl-C")

        stdout_reader.join(1)
        stderr_reader.join(1)
        assert_equal(130, wait_thread.value.exitstatus)
      end
    end
  end
end
