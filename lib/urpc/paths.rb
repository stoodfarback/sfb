# frozen_string_literal: true

module Urpc
  class Paths
    KEY_RE = /\A[0-9a-z_]+\z/

    attr_accessor(:key)

    def initialize(key)
      if !key.is_a?(String) || !KEY_RE.match?(key)
        raise(ArgumentError, "invalid urpc service key: #{key.inspect}")
      end
      self.key = key.freeze
    end

    def dir
      File.join(Urpc.root, key)
    end

    def server_lock
      File.join(dir, "server.lock")
    end

    def submit_fifo
      File.join(dir, "submit.fifo")
    end

    def calls_dir
      File.join(dir, "calls")
    end

    def output_dir
      File.join(dir, "output")
    end

    def input_dir
      File.join(dir, "input")
    end

    def call_file(id)
      File.join(calls_dir, "#{id.hex}.msgpack")
    end

    def output_fifo(id)
      File.join(output_dir, "#{id.hex}.fifo")
    end

    def input_fifo(id)
      File.join(input_dir, "#{id.hex}.fifo")
    end
  end
end
