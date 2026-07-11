# frozen_string_literal: true

module Urpc
  class Dispatch
    attr_accessor(:handlers)

    def initialize(**handlers)
      self.handlers = handlers.transform_values { normalize_handler(it) }.freeze
    end

    def call(req)
      handler_class = handlers.fetch(req.name) do
        raise(ArgumentError, "unknown urpc method: #{req.name}")
      end
      handler_class.new(req).run
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

    def normalize_handler(handler)
      if handler.respond_to?(:new)
        handler
      elsif handler.respond_to?(:to_proc)
        Class.new(Urpc::Handler) do
          define_method(:call, &handler)
        end
      else
        raise(ArgumentError, "urpc dispatch handler must respond to #new or #to_proc: #{handler.inspect}")
      end
    end
  end
end
