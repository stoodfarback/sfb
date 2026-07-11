# frozen_string_literal: true

module Urpc
  class Handler
    attr_accessor(:req)

    def initialize(req)
      self.req = req
    end

    def run
      value = call(*req.args, **req.kargs)
      req.finish_if_open(value)
      value
    end

    def call(...)
      raise(NotImplementedError, "#{self.class} must implement #call")
    end

    def data(value)
      req.data(value)
    end

    def finish(value = nil)
      req.finish(value)
    end

    def error(exception)
      req.error(exception)
    end

    def finished?
      req.finished?
    end
  end
end
