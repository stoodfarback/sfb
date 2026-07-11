# frozen_string_literal: true

module Urpc
  module Executor
    autoload(:ProcessPerRequest, "urpc/executor/process_per_request")
    autoload(:ProcessPool, "urpc/executor/process_pool")
    autoload(:ThreadPerRequest, "urpc/executor/thread_per_request")
    autoload(:ThreadPool, "urpc/executor/thread_pool")

    class Base
      attr_accessor(:paths, :handler)

      def start(paths:, handler:)
        self.paths = paths
        self.handler = handler
        self
      end

      def reserve
        nil
      end

      def submit(_reservation, accepted)
        execute(accepted)
      end

      def execute(accepted)
        Urpc::RequestRunner.call_accepted(handler, paths, accepted)
      end

      def close
        nil
      end

      def close_io(io)
        io.close if io && !io.closed?
      rescue IOError, Errno::EBADF
        nil
      end
    end

    class Pool < Base
      attr_accessor(:size)

      def initialize(size:)
        if !size.is_a?(Integer) || size <= 0
          raise(ArgumentError, "urpc executor pool size must be a positive integer")
        end

        self.size = size
      end
    end

    class Inline < Base
    end
  end
end
