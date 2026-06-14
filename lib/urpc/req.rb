# frozen_string_literal: true

module Urpc
  class Req
    attr_accessor(:args, :kargs, :stream, :bidirectional, :inbox_path)

    def initialize(args:, kargs:, stream:, bidirectional: false, inbox_path: nil)
      self.args = args
      self.kargs = kargs
      self.stream = stream
      self.bidirectional = bidirectional
      self.inbox_path = inbox_path
    end

    def bidirectional? = bidirectional == true

    def handle_with!(klass, *, **kargs)
      raise(ArgumentError, "#{klass} must be a Urpc::CallHandler") if !klass.is_a?(Class) || !(klass <= CallHandler)
      handler = klass.new(self, *, **kargs)
      handler.handle!
    end

    def handle_bidirectional!(klass, *, **kargs)
      raise(ArgumentError, "#{klass} must be a Urpc::BidirectionalHandler") if !klass.is_a?(Class) || !(klass <= BidirectionalHandler)
      raise(ArgumentError, "call was not requested as bidirectional") if !bidirectional?
      raise(ArgumentError, "missing inbox path") if !inbox_path.is_a?(String) || inbox_path.empty?
      handler = klass.new(self, *, **kargs)
      handler.handle!
    end
  end
end
