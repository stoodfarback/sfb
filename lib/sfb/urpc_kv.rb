# frozen_string_literal: true

module Sfb
  module UrpcKv
    RPC_KEY = "urpc_kv_v1"
    CLIENT_TIMEOUT_SECONDS = 1
    CLIENT_WAIT_FOR_SERVER_SECONDS = 1

    def self.read(key)
      rpc(:read, valid_string!(key))
    end

    def self.get(key)
      rpc(:get, valid_string!(key))
    end

    def self.set(key, value, ex: nil)
      rpc(:set, valid_string!(key), value, ex:)
    end

    def self.delete(key)
      rpc(:delete, valid_string!(key))
    end

    def self.exists?(key)
      rpc(:exists?, valid_string!(key))
    end

    def self.expire(key, seconds)
      rpc(:expire, valid_string!(key), seconds)
    end

    def self.delete_all_with_prefix(prefix)
      rpc(:delete_all_with_prefix, valid_string!(prefix))
    end

    def self.fetch(key, ex: nil, &block)
      if !block
        raise(ArgumentError, "Sfb::UrpcKv.fetch requires a block")
      end

      key = valid_string!(key)
      hit, value = read(key)
      return(value) if hit

      value = block.call
      set(key, value, ex:)
      value
    end

    def self.with_prefix(prefix)
      Scope.new(prefix)
    end

    def self.key(key)
      Key.new(key)
    end

    def self.valid_string!(value)
      raise(ArgumentError) if value.nil?
      value = value.to_s
      raise(ArgumentError) if value.empty?
      value
    end

    def self.rpc(method_name, ...)
      rpc_client.call(method_name, ...)
    end

    def self.rpc_client
      @rpc_client ||= Urpc::Client.new(
        RPC_KEY,
        timeout: CLIENT_TIMEOUT_SECONDS,
        wait_for_server: CLIENT_WAIT_FOR_SERVER_SECONDS,
      )
    end

    class Scope
      attr_accessor(:prefix)

      def initialize(prefix)
        self.prefix = Sfb::UrpcKv.valid_string!(prefix).dup.freeze
        freeze
      end

      def inspect
        "#<#{self.class} prefix=#{prefix.inspect}>"
      end

      def full_key(key)
        prefix + Sfb::UrpcKv.valid_string!(key)
      end

      # A scope only transforms keys; all service calls still go through root methods.
      def read(key)
        Sfb::UrpcKv.read(full_key(key))
      end

      def get(key)
        Sfb::UrpcKv.get(full_key(key))
      end

      def set(key, value, ex: nil)
        Sfb::UrpcKv.set(full_key(key), value, ex:)
      end

      def delete(key)
        Sfb::UrpcKv.delete(full_key(key))
      end

      def exists?(key)
        Sfb::UrpcKv.exists?(full_key(key))
      end

      def expire(key, seconds)
        Sfb::UrpcKv.expire(full_key(key), seconds)
      end

      def delete_all
        Sfb::UrpcKv.delete_all_with_prefix(prefix)
      end

      def delete_all_with_prefix(sub_prefix)
        Sfb::UrpcKv.delete_all_with_prefix(prefix + Sfb::UrpcKv.valid_string!(sub_prefix))
      end

      def fetch(key, ex: nil, &)
        Sfb::UrpcKv.fetch(full_key(key), ex:, &)
      end

      def with_prefix(sub_prefix)
        Sfb::UrpcKv.with_prefix(prefix + Sfb::UrpcKv.valid_string!(sub_prefix))
      end

      def key(key)
        Sfb::UrpcKv.key(full_key(key))
      end
    end

    class Key
      attr_accessor(:key)

      def initialize(key)
        self.key = Sfb::UrpcKv.valid_string!(key).dup.freeze
        freeze
      end

      def inspect
        "#<#{self.class} key=#{key.inspect}>"
      end

      def read
        Sfb::UrpcKv.read(key)
      end

      def get
        Sfb::UrpcKv.get(key)
      end

      def set(value, ex: nil)
        Sfb::UrpcKv.set(key, value, ex:)
      end

      def delete
        Sfb::UrpcKv.delete(key)
      end

      def exists?
        Sfb::UrpcKv.exists?(key)
      end

      def expire(seconds)
        Sfb::UrpcKv.expire(key, seconds)
      end

      def fetch(ex: nil, &)
        Sfb::UrpcKv.fetch(key, ex:, &)
      end
    end
  end
end
