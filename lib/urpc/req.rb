# frozen_string_literal: true

module Urpc
  class Req
    attr_accessor(:args, :kargs, :stream)

    def initialize(args:, kargs:, stream:)
      self.args = args
      self.kargs = kargs
      self.stream = stream
    end
  end
end
