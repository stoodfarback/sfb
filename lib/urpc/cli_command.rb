# frozen_string_literal: true

module Urpc
  class CliCommand < BidirectionalHandler
    attr_accessor(:command_name, :version, :argv, :cwd, :cancel_requested)

    def initialize(req, command_name: nil)
      super(req)
      self.command_name = (command_name || "command").to_s
      self.cancel_requested = false
      load_cli_request!
    end

    def load_cli_request!
      raise(ArgumentError, "cli request must have exactly one positional argument") if args.length != 1
      raise(ArgumentError, "cli request must not use keyword arguments") if !kargs.empty?

      request = args.first
      raise(ArgumentError, "cli request must be a Hash") if !request.is_a?(Hash)
      raise(ArgumentError, "unsupported cli protocol version: #{request[:version].inspect}") if request[:version] != 1
      raise(ArgumentError, "cli argv must be an Array of String") if !array_of_strings?(request[:argv])
      raise(ArgumentError, "cli cwd must be a non-empty String") if !non_empty_string?(request[:cwd])

      self.version = request[:version]
      self.argv = request[:argv]
      self.cwd = request[:cwd]
      nil
    end

    def run!
      set_defaults!

      status =
        if help_requested?
          stdout(help_text)
          0
        else
          parse_argv!
          validate!
          perform!
        end

      { status: normalize_status(status) }
    rescue OptionParser::ParseError, ArgumentError => e
      stderr("#{e.message}\n\n")
      stderr(help_text)
      { status: 2 }
    end

    def set_defaults!; end

    def help_requested?
      argv.include?("-h") || argv.include?("--help")
    end

    def parse_argv!; end
    def validate!; end

    def perform!
      raise("subclass must implement perform!")
    end

    def help_text
      "Usage: #{command_name}\n"
    end

    def stdout(payload)
      raise(ArgumentError, "stdout data must be a String") if !payload.is_a?(String)
      data({ type: :stdout, data: payload })
    end

    def stderr(payload)
      raise(ArgumentError, "stderr data must be a String") if !payload.is_a?(String)
      data({ type: :stderr, data: payload })
    end

    def glob(pattern)
      client_op(op: :glob, pattern: pattern)
    end

    def read_file(path)
      client_op(op: :read_file, path: path)
    end

    def list_dir(path)
      client_op(op: :list_dir, path: path)
    end

    def path_info(path)
      client_op(op: :path_info, path: path)
    end

    def read_env(name)
      client_op(op: :read_env, name: name)
    end

    def list_env(include_values: false)
      payload = { op: :list_env }
      payload[:include_values] = true if include_values
      client_op(payload)
    end

    def read_stdin
      client_op(op: :read_stdin)
    end

    def stdin_tty?
      client_op(op: :stdin_tty)
    end

    def stdout_tty?
      client_op(op: :stdout_tty)
    end

    def stderr_tty?
      client_op(op: :stderr_tty)
    end

    def cancelled?
      cancel_requested == true
    end

    def receive_async(value)
      self.cancel_requested = true if value.is_a?(Hash) && value[:type] == :cancel
    end

    def on_disconnect
      self.cancel_requested = true
    end

    def client_op(payload)
      data(payload.merge(type: :op))
      result = receive
      raise("malformed cli op result") if !valid_op_result?(result)

      if result[:ok]
        result[:value]
      else
        error = result[:error]
        raise("#{error[:exception]}: #{error[:message]}")
      end
    end

    def valid_op_result?(result)
      return false if !result.is_a?(Hash)
      return false if result[:type] != :op_result
      return true if result[:ok] == true
      return false if result[:ok] != false

      error = result[:error]
      error.is_a?(Hash) && error[:exception].is_a?(String) && error[:message].is_a?(String)
    end

    def normalize_status(status)
      status = 0 if status.nil?
      raise("invalid cli status: #{status.inspect}") if !status.is_a?(Integer)
      raise("invalid cli status: #{status.inspect}") if status < 0 || status > 255
      status
    end

    def array_of_strings?(value)
      value.is_a?(Array) && value.all?(String)
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
