# frozen_string_literal: true

module Urpc
  class Call
    class Invalid < StandardError; end

    attr_accessor(:id, :rpc_key, :name, :args, :kargs, :cast, :wait_for_server)

    def initialize(id:, rpc_key:, name:, args:, kargs:, cast:, wait_for_server: false)
      self.id = id
      self.rpc_key = rpc_key
      self.name = name
      self.args = args
      self.kargs = kargs
      self.cast = cast
      self.wait_for_server = wait_for_server
    end

    def cast?
      cast
    end

    def wait_for_server?
      wait_for_server
    end

    def request_path
      self.class.request_path(id)
    end

    def reply_path
      self.class.reply_path(id)
    end

    def write_request_file!
      File.open(request_path, File::WRONLY | File::CREAT | File::EXCL) do |io|
        io.write(MessagePack.pack(to_request_hash))
      end
    end

    def to_request_hash
      {
        rpc_key: rpc_key,
        name: name,
        args: args,
        kargs: kargs,
        cast: cast,
        wait_for_server: wait_for_server,
      }
    end

    def to_backend_request
      {
        name: name,
        args: args,
        kargs: kargs,
      }
    end

    def self.request_path(id)
      File.join(Urpc.requests_dir, "#{id}.msgpack")
    end

    def self.reply_path(id)
      File.join(Urpc.replies_dir, "#{id}.fifo")
    end

    def self.load(id)
      data = File.binread(request_path(id))
      hash = MessagePack.unpack(data)
      raise(Invalid, "missing or invalid fields") if !valid_request_hash?(hash)
      new(
        id: id,
        rpc_key: hash[:rpc_key],
        name: hash[:name],
        args: hash[:args],
        kargs: hash[:kargs],
        cast: hash[:cast],
        wait_for_server: hash[:wait_for_server],
      )
    end

    def self.valid_request_hash?(hash)
      hash.is_a?(Hash) &&
        hash[:rpc_key].is_a?(String) &&
        hash[:name].is_a?(Symbol) &&
        hash[:args].is_a?(Array) &&
        hash[:kargs].is_a?(Hash) &&
        [true, false].include?(hash[:cast]) &&
        [true, false].include?(hash[:wait_for_server])
    end
  end
end
