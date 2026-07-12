# frozen_string_literal: true

module Urpc
  class Dispatch
    attr_accessor(:endpoints)

    def initialize(**endpoints)
      self.endpoints = endpoints.transform_values { normalize_endpoint(it) }.freeze
    end

    def call(req)
      endpoint = endpoints.fetch(req.name) do
        raise(ArgumentError, "unknown urpc method: #{req.name}")
      end
      endpoint.handle(req)
    rescue Urpc::ClientDisconnected
      nil
    rescue => e
      handle_error(req, e)
    end

    def to_proc
      method(:call).to_proc
    end

    def handle_error(req, error)
      delivered = req.error_if_open(error)
      if req.cast? || !delivered
        warn_error(req, error)
      end
      nil
    rescue Urpc::ClientDisconnected
      nil
    end

    def warn_error(req, error)
      warn("urpc #{req.name} failed: #{error.class}: #{error.message}")
    end

    def normalize_endpoint(endpoint)
      if endpoint.respond_to?(:handle)
        endpoint
      elsif endpoint.respond_to?(:to_proc)
        Class.new(Urpc::Handler) do
          define_method(:call, &endpoint)
        end
      else
        raise(ArgumentError, "urpc dispatch endpoint must respond to #handle or #to_proc: #{endpoint.inspect}")
      end
    end
  end
end
