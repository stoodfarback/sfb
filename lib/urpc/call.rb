# frozen_string_literal: true

module Urpc
  class Call
    class Invalid < StandardError; end

    attr_accessor(:id, :rpc_key, :name, :args, :kargs, :cast, :wait_for_server, :bidirectional)

    def initialize(id:, rpc_key:, name:, args:, kargs:, cast:, wait_for_server: false, bidirectional: false)
      raise(ArgumentError, "invalid wait_for_server: #{wait_for_server.inspect}") if !self.class.valid_wait_for_server?(wait_for_server)
      raise(ArgumentError, "invalid bidirectional: #{bidirectional.inspect}") if ![true, false].include?(bidirectional)
      raise(ArgumentError, "bidirectional cast not supported") if cast && bidirectional
      if wait_for_server.is_a?(Numeric) && wait_for_server <= 0
        wait_for_server = false
      end
      self.id = id
      self.rpc_key = rpc_key
      self.name = name
      self.args = args
      self.kargs = kargs
      self.cast = cast
      self.wait_for_server = wait_for_server
      self.bidirectional = bidirectional
    end

    def cast?
      cast
    end

    def wait_for_server?
      wait_for_server == true || !!wait_for_server_seconds
    end

    def wait_for_server_seconds
      self.class.wait_for_server_seconds(wait_for_server)
    end

    def bidirectional?
      bidirectional == true
    end

    def request_path
      self.class.request_path(id)
    end

    def reply_path
      self.class.reply_path(id)
    end

    def body_payload
      MessagePack.pack([args, kargs])
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

    def self.inbox_path(id)
      File.join(Urpc.inboxes_dir, "#{id}.fifo")
    end

    def self.load(id, rpc_key:, name:, cast:, wait_for_server:, bidirectional: false)
      body = File.binread(request_path(id))
      load_body(id, body, rpc_key: rpc_key, name: name, cast: cast, wait_for_server: wait_for_server, bidirectional: bidirectional)
    end

    def self.load_body(id, body, rpc_key:, name:, cast:, wait_for_server:, bidirectional: false)
      data = MessagePack.unpack(body)
      raise(Invalid, "missing or invalid body") if !data.is_a?(Array) || data.size != 2
      args, kargs = data
      raise(Invalid, "missing or invalid body") if !args.is_a?(Array) || !kargs.is_a?(Hash)

      new(
        id: id,
        rpc_key: rpc_key,
        name: name.to_sym,
        args: args,
        kargs: kargs,
        cast: cast,
        wait_for_server: wait_for_server,
        bidirectional: bidirectional,
      )
    end

    def self.valid_wait_for_server?(value)
      return true if [true, false].include?(value)
      return false if !value.is_a?(Numeric)
      return false if value.respond_to?(:nan?) && value.nan?
      return false if value.respond_to?(:infinite?) && value.infinite?
      value >= 0
    rescue ArgumentError
      false
    end

    def self.wait_for_server_seconds(value)
      return if !valid_wait_for_server?(value)
      return if !value.is_a?(Numeric)
      return if value <= 0
      value
    end
  end
end
