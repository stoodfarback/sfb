# frozen_string_literal: true

module Urpc
  class CallHandler
    attr_accessor(:req)

    def initialize(req)
      self.req = req
    end

    def handle!
      result = run!
      finish(result) if !finished?
    rescue => e
      error(e) if !finished?
    end

    def run!
      raise("subclass must implement run!")
    end

    def args = req.args
    def kargs = req.kargs
    def stream = req.stream

    def data(value) = stream.data(value)
    def finish(value = nil) = stream.return(value)
    def error(exception) = stream.error(exception)
    def finished? = stream.is_finished
    def send_frame(type, value) = stream.write_response(type, value)
  end
end
