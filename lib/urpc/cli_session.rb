# frozen_string_literal: true

module Urpc
  class CliSession < Urpc::BidirectionalHandler
    attr_accessor(:command_class, :caller_cwd, :cancel_requested)

    def initialize(req, command_class:)
      super(req)
      self.command_class = command_class
      self.cancel_requested = false
    end

    def call(argv:, caller_cwd:)
      validate_invocation!(argv:, caller_cwd:)
      self.caller_cwd = caller_cwd

      command_class.new(session: self, command_name: req.name.to_s, argv:).run
    end

    def validate_invocation!(argv:, caller_cwd:)
      raise(ArgumentError, "cli argv must be an Array of String") if !array_of_strings?(argv)
      raise(ArgumentError, "cli caller_cwd must be a non-empty String") if !non_empty_string?(caller_cwd)
    end

    def stdout(payload)
      raise(ArgumentError, "stdout data must be a String") if !payload.is_a?(String)

      data(type: :stdout, data: payload)
    end

    def stderr(payload)
      raise(ArgumentError, "stderr data must be a String") if !payload.is_a?(String)

      data(type: :stderr, data: payload)
    end

    def glob(pattern)
      caller_operation(op: :glob, pattern:)
    end

    def read_file_binary(path)
      caller_operation(op: :read_file_binary, path:)
    end

    def read_file_utf8(path)
      caller_operation(op: :read_file_utf8, path:)
    end

    def list_dir(path)
      caller_operation(op: :list_dir, path:)
    end

    def path_info(path)
      caller_operation(op: :path_info, path:)
    end

    def read_env(name)
      caller_operation(op: :read_env, name:)
    end

    def list_env(include_values: false)
      payload = { op: :list_env }
      if include_values
        payload[:include_values] = true
      end
      caller_operation(payload)
    end

    def read_stdin
      caller_operation(op: :read_stdin)
    end

    def stdin_tty?
      caller_operation(op: :stdin_tty)
    end

    def stdout_tty?
      caller_operation(op: :stdout_tty)
    end

    def stderr_tty?
      caller_operation(op: :stderr_tty)
    end

    def cancelled?
      cancel_requested == true
    end

    def receive_async(value)
      if !value.is_a?(Hash) || value[:type] != :cancel
        raise(ArgumentError, "unsupported cli async input: #{value.inspect}")
      end

      self.cancel_requested = true
    end

    def on_disconnect
      self.cancel_requested = true
    end

    def caller_operation(payload)
      data(payload.merge(type: :op))
      result = receive
      raise("malformed cli operation result") if !valid_operation_result?(result)

      if result[:ok]
        result[:value]
      else
        error = result[:error]
        raise("#{error[:exception]}: #{error[:message]}")
      end
    end

    def valid_operation_result?(result)
      return false if !result.is_a?(Hash)
      return false if result[:type] != :op_result
      return true if result[:ok] == true
      return false if result[:ok] != false

      error = result[:error]
      error.is_a?(Hash) && error[:exception].is_a?(String) && error[:message].is_a?(String)
    end

    def array_of_strings?(value)
      value.is_a?(Array) && value.all?(String)
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
