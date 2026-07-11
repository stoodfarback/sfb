# frozen_string_literal: true

module Urpc
  class BidirectionalHandler < Urpc::Handler
    attr_accessor(:input)

    def initialize(req)
      super(req)
      if !req.bidirectional?
        raise(ArgumentError, "urpc request is not bidirectional")
      end
      self.input = Urpc::BidirectionalInput.new(req, owner: self)
    end

    def run
      input.start
      super
    ensure
      input.close
    end

    def receive
      input.receive
    end

    def receive_async(value)
      raise(NotImplementedError, "#{self.class} must implement #receive_async for #{value.inspect}")
    end

    def disconnected?
      input.disconnected?
    end

    def close_input
      input.close
    end

    def on_disconnect
      nil
    end
  end
end
