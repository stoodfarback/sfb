# frozen_string_literal: true

module Sfb
  class LsbClient
    SOCKET_PATH = "/run/user/#{Process.uid}/lsb.sock".freeze
    MAX_LINE_BYTES = 16 * 1024
    RESPONSE_TIMEOUT_SECONDS = 2
    ID_RE = /\A[a-z0-9]{1,50}\z/

    class Error < StandardError; end
    class BrokerDown < Error; end
    class Denied < Error; end
    class ProtocolError < Error; end
    class InvalidRequest < Error; end

    attr_accessor(:project_id, :project_name, :cache)

    def self.init!(project_name, project_id)
      @singleton = new(project_id:, project_name:)
    end

    def self.fetch(secret_name)
      instance = @singleton
      raise(Error, "LsbClient not initialized") unless instance
      instance.fetch(secret_name)
    end

    def initialize(project_id:, project_name:)
      validate_id!(project_id, "project_id")
      validate_id!(project_name, "project_name")

      self.project_id = project_id
      self.project_name = project_name
      self.cache = {}
    end

    def fetch(secret_name)
      validate_id!(secret_name, "secret_name")

      return cache[secret_name] if cache.key?(secret_name)

      request = {
        "project_id" => project_id,
        "project_name" => project_name,
        "secret_name" => secret_name,
      }

      line = exchange("#{JSON.generate(request)}\n")
      resp = parse_response(line)

      if resp["ok"] == true
        b64 = resp["value_b64"]
        raise(ProtocolError, "Missing value_b64") unless b64.is_a?(String)
        value = Base64.strict_decode64(b64)
        cache[secret_name] = value
        value
      else
        raise(Denied, "denied")
      end
    end

    def validate_id!(value, label)
      if !value.is_a?(String) || !ID_RE.match?(value)
        raise(InvalidRequest, "Invalid #{label}: #{value.inspect}")
      end
    end

    def exchange(payload)
      ExchangeHelper.exchange(
        payload:,
        socket_path: SOCKET_PATH,
        max_line_bytes: MAX_LINE_BYTES,
        timeout_seconds: RESPONSE_TIMEOUT_SECONDS
      )
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES => e
      raise(BrokerDown, "Broker unavailable (#{e.class})")
    end

    def parse_response(line)
      JSON.parse(line)
    rescue JSON::ParserError => e
      raise(ProtocolError, "Invalid JSON response: #{e.message}")
    end

    class ExchangeHelper
      attr_accessor(:payload, :socket_path, :max_line_bytes, :deadline, :sock)

      def self.exchange(...)
        new(...).()
      end

      def initialize(payload:, socket_path:, max_line_bytes:, timeout_seconds:)
        self.payload = payload
        self.socket_path = socket_path
        self.max_line_bytes = max_line_bytes
        self.deadline = self.class.monotonic_deadline(timeout_seconds)
      end

      def call
        self.sock = connect_with_timeout
        write_with_timeout
        read_line_with_deadline
      ensure
        sock&.close rescue nil
      end

      def self.monotonic_deadline(seconds)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      end

      def self.remaining_seconds(deadline)
        deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def connect_with_timeout
        self.sock = Socket.new(:UNIX, :STREAM, 0)
        addr = Socket.sockaddr_un(socket_path)
        begin
          sock.connect_nonblock(addr)
        rescue IO::WaitWritable, Errno::EINPROGRESS
          wait_for(:writable, "connecting to broker")
          begin
            sock.connect_nonblock(addr)
          rescue Errno::EISCONN
            # Connected.
          end
        end
        sock
      end

      def write_with_timeout
        total = 0
        while total < payload.bytesize
          wait_for(:writable, "waiting to write to broker")
          chunk = payload.byteslice(total, payload.bytesize - total)
          written = sock.write_nonblock(chunk, exception: false)
          if written == :wait_writable
            next
          end
          total += written
        end
        sock.flush rescue nil
      end

      def read_line_with_deadline
        buffer = +""
        loop do
          wait_for(:readable, "waiting for broker response")

          chunk = sock.read_nonblock(1024, exception: false)
          if chunk == :wait_readable
            next
          elsif chunk.nil?
            break
          else
            buffer << chunk
          end

          newline_index = buffer.index("\n")
          if newline_index
            raise(ProtocolError, "Response too large or missing newline") if newline_index > max_line_bytes
            return buffer[0..newline_index]
          end

          if buffer.bytesize > max_line_bytes
            raise(ProtocolError, "Response too large or missing newline")
          end
        end

        raise(ProtocolError, "No response from broker") if buffer.empty?
        raise(ProtocolError, "Response too large or missing newline")
      end

      def wait_for(direction, context)
        remaining = self.class.remaining_seconds(deadline)
        raise(ProtocolError, "Timed out #{context}") if remaining <= 0
        ready = if direction == :readable
          sock.wait_readable(remaining)
        else
          sock.wait_writable(remaining)
        end
        raise(ProtocolError, "Timed out #{context}") if ready.nil?
      end
    end
  end
end
