# frozen_string_literal: true

module Urpc
  class Server
    attr_accessor(:key, :executor, :paths, :lock, :submit_io, :submit_reader)

    def initialize(key, executor: nil, &handler)
      if !handler
        raise(ArgumentError, "urpc server requires a handler block")
      end

      self.key = Urpc::Paths.new(key).key
      self.executor = executor || Urpc::Executor::Inline.new
      if !self.executor.is_a?(Urpc::Executor::Base)
        raise(ArgumentError, "urpc executor must be an Urpc::Executor::Base")
      end

      service = Urpc::ServiceDir.new(self.key)
      self.paths = service.paths
      begin
        self.executor.start(paths:, handler:)
        self.lock = service.acquire_server_lock!
        self.submit_io = File.open(paths.submit_fifo, File::RDWR | File::NONBLOCK)
        self.submit_reader = Urpc::SubmitReader.new(paths, submit_io)
      rescue
        close
        raise
      end
    end

    def run
      loop do
        return if closed?

        reservation = executor.reserve
        accepted = submit_reader.next_accepted
        executor.submit(reservation, accepted)
      end
    rescue IOError, Errno::EBADF
      raise if !closed?
    end

    def close
      if submit_reader && !submit_reader.closed?
        submit_reader.close
      end
      if lock && !lock.closed?
        lock.close
      end
      executor&.close
      nil
    end

    def closed?
      !submit_reader || submit_reader.closed?
    end
  end
end
