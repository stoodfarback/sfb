# frozen_string_literal: true

module Urpc
  class Server < StreamServer
    def initialize(rpc_key, handler)
      super(rpc_key, WrapHandler.new(handler))
    end

    class WrapHandler
      attr_accessor(:handler)

      def initialize(handler)
        self.handler = handler
      end

      def method_missing(name, req)
        dispatch(name, req)
      end

      # Object#respond_to? would intercept :respond_to? RPC calls; redirect them.
      def respond_to?(arg, include_private = false)
        arg.is_a?(Req) ? dispatch(:respond_to?, arg) : super
      end

      def respond_to_missing?(name, include_private = false)
        handler.respond_to?(name, include_private)
      end

      def dispatch(name, req)
        ret = handler.send(name, *req.args, **req.kargs)
        req.stream.return(ret)
        nil
      end
    end
  end
end
