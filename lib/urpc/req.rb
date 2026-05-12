# frozen_string_literal: true

module Urpc
  class Req
    attr_accessor(:args, :kargs, :stream)

    def initialize(args:, kargs:, stream:)
      self.args = args
      self.kargs = kargs
      self.stream = stream
    end

    def handle_with!(klass, *args, **kargs)
      raise(ArgumentError, "#{klass} must be a Urpc::CallHandler") if !klass.is_a?(Class) || !(klass <= CallHandler)
      handler = klass.new(self, *args, **kargs)
      handler.handle!
    end

    def handle_bidirectional!(klass, *args, **kargs)
      raise(ArgumentError, "#{klass} must be a Urpc::BidirectionalHandler") if !klass.is_a?(Class) || !(klass <= BidirectionalHandler)
      handler = klass.new(self, *args, **kargs)
      handler.handle!
    end
  end
end
