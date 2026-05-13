# frozen_string_literal: true

module Urpc
  class CliClient
    POLL_INTERVAL = 0.05
    INTERRUPT_WINDOW = 5.0
    FORCE_QUIT_GRACE = 1.0

    attr_accessor(:argv, :rpc_key, :command, :command_argv, :wait_for_server, :root,
      :cwd, :stdin_consumed, :interrupt_count, :first_interrupt_at, :force_quit_started_at,
      :cancel_sent, :stream)

    def self.run
      new(ARGV.dup).run
    rescue => e
      $stderr.puts("Error: #{e.message}")
      1
    end

    def initialize(argv)
      self.argv = argv
      self.wait_for_server = 5
      self.stdin_consumed = false
      self.interrupt_count = 0
      self.cancel_sent = false
    end

    def run
      parse!
      Urpc.set_root(root) if root
      self.cwd = Dir.pwd

      previous_int_handler = Signal.trap("INT") { record_interrupt }
      begin
        request = { version: 1, argv: command_argv, cwd: cwd }
        client = Client.new(rpc_key, wait_for_server: wait_for_server)
        self.stream = client.bidirectional_stream(command.to_sym, request)
        run_stream_loop
        result = stream.result
        return cli_status(result)
      ensure
        stream&.close
        Signal.trap("INT", previous_int_handler) if previous_int_handler
      end
    end

    def parse!
      args = argv.dup
      parse_client_options!(args)

      self.rpc_key = args.shift
      self.command = args.shift
      self.command_argv = args

      raise(ArgumentError, usage) if !non_empty_string?(rpc_key) || !non_empty_string?(command)
      nil
    end

    def parse_client_options!(args)
      loop do
        arg = args.first
        return if !arg
        if arg == "--"
          args.shift
          return
        end
        return if !arg.start_with?("-")

        args.shift
        case arg
        when "-h", "--help"
          $stdout.write(usage)
          exit(0)
        when "--wait-for-server"
          self.wait_for_server = parse_seconds(args.shift, "--wait-for-server")
        when /\A--wait-for-server=(.+)\z/
          self.wait_for_server = parse_seconds(Regexp.last_match(1), "--wait-for-server")
        when "--root"
          self.root = require_option_value(args.shift, "--root")
        when /\A--root=(.+)\z/
          self.root = Regexp.last_match(1)
        else
          raise(ArgumentError, "unknown client option: #{arg}")
        end
      end
    end

    def usage
      "usage: urpc-call-cli [--wait-for-server SECONDS] [--root PATH] <rpc_key> <command> [argv...]\n"
    end

    def run_stream_loop
      loop do
        process_interrupts
        break if stream.finished?

        if stream.has_pending?
          process_stream_event(stream.consume_pending)
          next
        end

        ready = IO.select([stream.reply_io], nil, nil, select_timeout)
        if ready
          stream.fill_buffer_once
        else
          check_force_quit_deadline
        end
      end
    end

    def process_stream_event(event)
      return if stream.handle_event(event) == :internal
      return if event.type != :data

      process_cli_event(event.data)
    end

    def process_cli_event(event)
      protocol_error("malformed cli event") if !event.is_a?(Hash)

      case event[:type]
      when :stdout
        write_stream($stdout, event[:data], :stdout)
      when :stderr
        write_stream($stderr, event[:data], :stderr)
      when :op
        stream.send_sync(perform_operation(event))
      else
        protocol_error("unknown cli event type: #{event[:type].inspect}")
      end
    end

    def write_stream(io, data, label)
      protocol_error("cli #{label} event data must be a String") if !data.is_a?(String)
      io.write(data)
      io.flush
    end

    def perform_operation(event)
      begin
        { type: :op_result, ok: true, value: operation_value(event) }
      rescue => e
        {
          type: :op_result,
          ok: false,
          error: {
            exception: e.class.to_s,
            message: e.message,
          },
        }
      end
    end

    def operation_value(event)
      case event[:op]
      when :glob
        op_glob(event)
      when :read_file
        File.binread(resolve_path(fetch_string(event, :path)))
      when :list_dir
        op_list_dir(event)
      when :read_env
        ENV[fetch_string(event, :name)]
      when :list_env
        op_list_env(event)
      when :read_stdin
        op_read_stdin
      else
        raise(ArgumentError, "unsupported cli op: #{event[:op]}")
      end
    end

    def op_glob(event)
      pattern = fetch_string(event, :pattern)
      if absolute_path?(pattern)
        Dir.glob(pattern)
      else
        Dir.glob(pattern, base: cwd)
      end
    end

    def op_list_dir(event)
      requested_path = fetch_string(event, :path)
      absolute_dir = resolve_path(requested_path)
      Dir.children(absolute_dir).sort.map do |name|
        entry_path = File.join(absolute_dir, name)
        {
          name: name,
          path: File.join(requested_path, name),
          type: file_type(entry_path),
        }
      end
    end

    def op_list_env(event)
      include_values = event.fetch(:include_values, false)
      raise(ArgumentError, "include_values must be true or false") if ![true, false].include?(include_values)
      return ENV.keys.sort if !include_values
      ENV.to_h.sort.to_h
    end

    def op_read_stdin
      return "" if stdin_consumed
      self.stdin_consumed = true
      $stdin.read || ""
    end

    def file_type(path)
      stat = File.lstat(path)
      return :symlink if stat.symlink?
      return :file if stat.file?
      return :dir if stat.directory?
      :other
    end

    def fetch_string(hash, key)
      value = hash[key]
      raise(ArgumentError, "#{key} must be a String") if !value.is_a?(String)
      value
    end

    def resolve_path(path)
      return path if absolute_path?(path)
      File.expand_path(path, cwd)
    end

    def absolute_path?(path)
      path.start_with?("/")
    end

    def cli_status(result)
      raise("malformed cli return") if !result.is_a?(Hash)
      status = result[:status]
      raise("malformed cli status: #{status.inspect}") if !status.is_a?(Integer)
      raise("malformed cli status: #{status.inspect}") if status < 0 || status > 255
      status
    end

    def protocol_error(message)
      stream&.close_inbox
      raise(message)
    end

    def record_interrupt
      now = monotonic_now
      if first_interrupt_at && now - first_interrupt_at <= INTERRUPT_WINDOW
        self.interrupt_count += 1
      else
        self.interrupt_count = 1
        self.first_interrupt_at = now
        self.cancel_sent = false
      end
    end

    def process_interrupts
      return if interrupt_count <= 0

      if interrupt_count == 1
        send_cancel_if_possible
      elsif interrupt_count == 2
        start_force_quit_wait
      else
        exit(130)
      end
      check_force_quit_deadline
    end

    def send_cancel_if_possible
      return if cancel_sent
      return if !stream&.inbox_open?

      stream.send_async(type: :cancel, reason: :interrupt)
      self.cancel_sent = true
      $stderr.write("\n\nsent Ctrl-C to server (press again to force quit)\n") if $stderr.tty?
      $stderr.flush
    rescue IOError, Errno::EPIPE
      start_force_quit_wait
    end

    def start_force_quit_wait
      return if force_quit_started_at

      stream&.close_inbox
      self.force_quit_started_at = monotonic_now
    end

    def check_force_quit_deadline
      return if !force_quit_started_at
      exit(130) if monotonic_now - force_quit_started_at >= FORCE_QUIT_GRACE
    end

    def select_timeout
      current = stream.current_wait_timeout
      raise(TimeoutException, "server response deadline exceeded") if current && current <= 0
      return POLL_INTERVAL if !current
      [current, POLL_INTERVAL].min
    end

    def parse_seconds(value, option_name)
      value = require_option_value(value, option_name)
      seconds = Float(value, exception: false)
      raise(ArgumentError, "#{option_name} must be a non-negative number") if !seconds || seconds.negative?
      seconds
    end

    def require_option_value(value, option_name)
      raise(ArgumentError, "#{option_name} requires a value") if !value || value.empty?
      value
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty?
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
