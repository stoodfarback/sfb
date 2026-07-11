# frozen_string_literal: true

module Urpc
  class RequestRunner
    def self.call_accepted(handler, paths, accepted)
      submit = accepted.hydrate(paths)
      server_call = Urpc::ServerCall.open(paths, submit)
      return if !server_call

      call(handler, Urpc::Req.new(server_call))
    end

    def self.call(handler, req)
      handler.call(req)
    rescue Urpc::ClientDisconnected
      nil
    end
  end
end
