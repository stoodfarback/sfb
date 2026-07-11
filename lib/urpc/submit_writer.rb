# frozen_string_literal: true

module Urpc
  class SubmitWriter
    WRITE_TIMEOUT = 5.0
    OPEN_RETRY_SLEEP = 0.01

    attr_accessor(:paths, :io)

    def initialize(paths, io)
      self.paths = paths
      self.io = io
    end

    def self.open(key, wait_for_server:)
      validate_wait_for_server!(wait_for_server)
      service = Urpc::ServiceDir.new(key)
      paths = service.paths

      io =
        if wait_for_server == false || wait_for_server == 0
          open_nonblocking(paths)
        elsif wait_for_server == true
          service.prepare!
          File.open(paths.submit_fifo, File::WRONLY)
        else
          service.prepare!
          open_nonblocking_until(paths, wait_for_server.to_f)
        end

      new(paths, io)
    rescue Errno::ENOENT, Errno::ENXIO
      raise(Urpc::NoServerError, "no urpc server for #{paths.key}")
    end

    def self.open_nonblocking(paths)
      File.open(paths.submit_fifo, File::WRONLY | File::NONBLOCK)
    end

    def self.open_nonblocking_until(paths, wait_seconds)
      deadline = Urpc::Deadline.after(wait_seconds)

      loop do
        begin
          return open_nonblocking(paths)
        rescue Errno::ENOENT, Errno::ENXIO
          remaining = deadline.remaining
          if remaining <= 0
            raise
          end

          sleep([OPEN_RETRY_SLEEP, remaining].min)
        end
      end
    end

    def self.validate_wait_for_server!(value)
      return if value == false || value == true

      Urpc::Deadline.validate_duration!(value, name: "wait_for_server")
    end

    def write(bytes)
      if bytes.bytesize > Urpc::SubmitFrame::ATOMIC_WRITE_BYTES
        raise(ArgumentError, "submit frame too large: #{bytes.bytesize}")
      end

      if !io.wait_writable(WRITE_TIMEOUT)
        raise(Urpc::NoServerError, "submit fifo not writable for #{paths.key}")
      end

      written = io.write_nonblock(bytes, exception: false)
      if written == :wait_writable
        raise(Urpc::NoServerError, "submit fifo not writable for #{paths.key}")
      end
      if written != bytes.bytesize
        raise("short submit write for #{paths.key}: #{written}/#{bytes.bytesize}")
      end

      written
    rescue Errno::EAGAIN, Errno::EPIPE
      raise(Urpc::NoServerError, "submit failed for #{paths.key}")
    end

    def close
      if !io.closed?
        io.close
      end
    end

    def closed?
      io.closed?
    end
  end
end
