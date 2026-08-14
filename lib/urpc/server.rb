# frozen_string_literal: true

module Urpc
  class Server
    attr_accessor(:key, :executor, :temporary, :service, :lock, :submit_io, :submit_reader)

    def paths = service.paths

    def initialize(key, executor: nil, temporary: false, &handler)
      if !handler
        raise(ArgumentError, "urpc server requires a handler block")
      end

      self.key = Urpc::Paths.new(key).key
      self.executor = executor || Urpc::Executor::Inline.new
      self.temporary = temporary
      if !self.executor.is_a?(Urpc::Executor::Base)
        raise(ArgumentError, "urpc executor must be an Urpc::Executor::Base")
      end

      self.service = Urpc::ServiceDir.new(self.key)
      begin
        self.executor.start(paths:, handler:)
        self.lock = service.acquire_server_lock!
        self.submit_io = File.open(paths.submit_fifo, File::RDWR | File::NONBLOCK)
        self.submit_reader = Urpc::SubmitReader.new(paths, submit_io)
      rescue => error
        shutdown(error)
        raise
      end
    end

    def run
      primary_error = nil
      begin
        loop do
          return if closed?

          reservation = executor.reserve
          accepted = submit_reader.next_accepted
          executor.submit(reservation, accepted)
        end
      rescue IOError, Errno::EBADF
        raise if !closed?
      end
    rescue Exception => error
      primary_error = error
      raise
    ensure
      shutdown(primary_error)
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

    def shutdown(primary_error)
      errors = []
      capture_shutdown_error(errors) { close }
      capture_shutdown_error(errors) { service.remove_if_unowned! } if temporary

      if primary_error
        errors.each { report_shutdown_error(it) }
        return
      end
      return if errors.empty?

      errors.drop(1).each { report_shutdown_error(it) }
      raise(errors.first)
    end

    def capture_shutdown_error(errors)
      yield
    rescue Exception => error
      errors << error
    end

    def report_shutdown_error(error)
      warn("urpc server shutdown also failed: #{error.class}: #{error.message}")
    end

    def closed?
      !submit_reader || submit_reader.closed?
    end
  end
end
