# frozen_string_literal: true

module Urpc
  class CliCommand
    attr_accessor(:session, :command_name, :argv)

    def self.handle(req)
      Urpc::CliSession.new(req, command_class: self).run
    end

    def initialize(session:, command_name:, argv:)
      self.session = session
      self.command_name = command_name
      self.argv = argv
    end

    def run
      set_defaults!
      return show_help if help_requested?

      begin
        parse_argv!
        validate!
      rescue OptionParser::ParseError, ArgumentError => e
        return show_usage_error(e)
      end

      normalize_status(execute!)
    end

    def execute!
      perform!
    end

    def run_subcommand(command_class, command_name:, argv:, **command_kargs)
      command_class.new(session:, command_name:, argv:, **command_kargs).run
    end

    def show_help
      stdout(help_text)
      0
    end

    def show_usage_error(error)
      stderr("#{error.message}\n\n")
      stderr(help_text)
      2
    end

    def set_defaults!; end

    def help_requested?
      argv == ["-h"] || argv == ["--help"]
    end

    def parse_argv!; end
    def validate!; end

    def perform!
      raise("subclass must implement perform!")
    end

    def help_text
      "Usage: #{command_name}\n"
    end

    def caller_cwd
      session.caller_cwd
    end

    def stdout(...)
      session.stdout(...)
    end

    def stderr(...)
      session.stderr(...)
    end

    def glob(...)
      session.glob(...)
    end

    def read_file_binary(...)
      session.read_file_binary(...)
    end

    def read_file_utf8(...)
      session.read_file_utf8(...)
    end

    def list_dir(...)
      session.list_dir(...)
    end

    def path_info(...)
      session.path_info(...)
    end

    def read_env(...)
      session.read_env(...)
    end

    def list_env(...)
      session.list_env(...)
    end

    def read_stdin
      session.read_stdin
    end

    def stdin_tty?
      session.stdin_tty?
    end

    def stdout_tty?
      session.stdout_tty?
    end

    def stderr_tty?
      session.stderr_tty?
    end

    def cancelled?
      session.cancelled?
    end

    def finished?
      session.finished?
    end

    def normalize_status(status)
      status = 0 if status.nil?
      raise("invalid cli status: #{status.inspect}") if !status.is_a?(Integer)
      raise("invalid cli status: #{status.inspect}") if status < 0 || status > 255

      status
    end
  end
end
