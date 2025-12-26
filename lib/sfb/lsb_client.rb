# frozen_string_literal: true

module Sfb
  class LsbClient
    SOCKET_PATH = "/run/user/#{Process.uid}/lsb.sock"
    MAX_LINE_BYTES = 16 * 1024
    ID_RE = /\A[a-z0-9]{1,50}\z/

    class Error < StandardError; end
    class BrokerDown < Error; end
    class Denied < Error; end
    class ProtocolError < Error; end
    class InvalidRequest < Error; end

    attr_accessor(:project_id, :project_name)

    def initialize(project_id:, project_name:)
      validate_id!(project_id, "project_id")
      validate_id!(project_name, "project_name")

      self.project_id = project_id
      self.project_name = project_name
    end

    def fetch(secret_name)
      validate_id!(secret_name, "secret_name")

      request = {
        "project_id" => project_id,
        "project_name" => project_name,
        "secret_name" => secret_name
      }

      line = exchange("#{JSON.generate(request)}\n")
      resp = parse_response(line)

      if resp["ok"] == true
        b64 = resp["value_b64"]
        raise(ProtocolError, "Missing value_b64") unless b64.is_a?(String)
        Base64.strict_decode64(b64)
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
      sock = UNIXSocket.new(SOCKET_PATH)
      sock.write(payload)
      sock.flush rescue nil
      line = sock.gets(MAX_LINE_BYTES + 1)
      raise(ProtocolError, "No response from broker") if line.nil?
      raise(ProtocolError, "Response too large or missing newline") unless line.end_with?("\n")
      line
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES => e
      raise(BrokerDown, "Broker unavailable (#{e.class})")
    ensure
      sock&.close rescue nil
    end

    def parse_response(line)
      JSON.parse(line)
    rescue JSON::ParserError => e
      raise(ProtocolError, "Invalid JSON response: #{e.message}")
    end
  end
end
