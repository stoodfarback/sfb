# frozen_string_literal: true

module Urpc::Executor
  class ProcessPerRequest < Base
    attr_accessor(:forker_pid, :request_io, :ready_io, :closed)

    def initialize
      self.closed = true
    end

    def start(...)
      super
      self.closed = false
      spawn_forker
      self
    rescue
      close
      raise
    end

    def reserve
      readable = IO.select([ready_io])&.first
      if !readable
        raise("urpc process-per-request forker is unavailable")
      end

      byte = ready_io.read_nonblock(1, exception: false)
      if byte.nil?
        raise("urpc process-per-request forker #{forker_pid} exited")
      end
      if byte == :wait_readable
        return reserve
      end
      if byte != Urpc::ProcessIpc::READY_BYTE
        raise("invalid urpc process-per-request ready byte")
      end
      nil
    end

    def submit(_reservation, accepted)
      Urpc::ProcessIpc.write_message(request_io, accepted.bytes)
      nil
    rescue Errno::EPIPE
      raise("urpc process-per-request forker exited") if !closed
    end

    def close
      return if closed

      self.closed = true
      close_io(request_io)
      close_io(ready_io)
      nil
    end

    def spawn_forker
      request_reader, request_writer = IO.pipe
      ready_reader, ready_writer = IO.pipe

      self.forker_pid = fork do
        request_writer.close
        ready_reader.close
        forker_process(request_reader, ready_writer)
      end
      Process.detach(forker_pid)

      request_reader.close
      ready_writer.close
      self.request_io = request_writer
      self.ready_io = ready_reader
    rescue
      close_io(request_reader)
      close_io(request_writer)
      close_io(ready_reader)
      close_io(ready_writer)
      raise
    end

    def forker_process(request_io, ready_io)
      loop do
        Urpc::ProcessIpc.write_ready(ready_io)
        bytes = Urpc::ProcessIpc.read_message(request_io)
        break if !bytes

        fork_request(bytes, request_io, ready_io)
      end
      exit!(0)
    rescue EOFError, Errno::EPIPE
      exit!(0)
    rescue Exception => e
      warn("urpc process-per-request forker failed: #{e.class}: #{e.message}")
      exit!(1)
    end

    def fork_request(bytes, request_io, ready_io)
      intermediate_pid = fork do
        request_io.close
        ready_io.close

        fork do
          request_process(bytes)
        end
        exit!(0)
      end

      _pid, status = Process.waitpid2(intermediate_pid)
      if !status.success?
        raise("urpc process-per-request intermediate fork failed")
      end
      nil
    end

    def request_process(bytes)
      accepted = Urpc::SubmitReader::Accepted.new(bytes: bytes.freeze)
      execute(accepted)
      exit!(0)
    rescue Exception => e
      warn("urpc process-per-request child failed: #{e.class}: #{e.message}")
      exit!(1)
    end

  end
end
