# frozen_string_literal: true

module Urpc::Executor
  class ProcessPool < Pool
    PipeSet = Data.define(:request_reader, :request_writer, :ready_reader, :ready_writer)
    Worker = Data.define(:pid, :request_io, :ready_io)

    attr_accessor(:workers, :closed)

    def initialize(size:)
      super
      self.workers = []
      self.closed = true
    end

    def start(...)
      super
      self.closed = false
      self.workers = spawn_workers
      self
    rescue
      close
      raise
    end

    def reserve
      ready_ios = workers.map(&:ready_io)
      readable = IO.select(ready_ios)&.first
      if !readable
        raise("urpc process pool has no workers")
      end

      ready_io = readable.first
      byte = ready_io.read_nonblock(1, exception: false)
      if byte.nil?
        worker = workers.find { it.ready_io == ready_io }
        raise("urpc process pool worker #{worker.pid} exited")
      end
      if byte == :wait_readable
        return reserve
      end
      if byte != Urpc::ProcessIpc::READY_BYTE
        raise("invalid urpc process worker ready byte")
      end

      workers.find { it.ready_io == ready_io }
    end

    def submit(worker, accepted)
      Urpc::ProcessIpc.write_message(worker.request_io, accepted.bytes)
      nil
    rescue Errno::EPIPE
      raise("urpc process pool worker exited") if !closed
    end

    def close
      return if closed

      self.closed = true
      workers.each do |worker|
        close_io(worker.request_io)
        close_io(worker.ready_io)
      end
      nil
    end

    def spawn_workers
      pids = []
      detached_pids = []
      pipe_sets = Array.new(size) do
        request_reader, request_writer = IO.pipe
        ready_reader, ready_writer = IO.pipe
        PipeSet.new(request_reader:, request_writer:, ready_reader:, ready_writer:)
      end

      pipe_sets.each_index do |index|
        pids << fork do
          worker_process(index, pipe_sets)
        end
      end

      pids.each do |pid|
        Process.detach(pid)
        detached_pids << pid
      end
      pipe_sets.zip(pids).map do |pipe_set, pid|
        pipe_set.request_reader.close
        pipe_set.ready_writer.close
        Worker.new(pid:, request_io: pipe_set.request_writer, ready_io: pipe_set.ready_reader)
      end
    rescue
      pipe_sets&.each do |pipe_set|
        close_io(pipe_set.request_reader)
        close_io(pipe_set.request_writer)
        close_io(pipe_set.ready_reader)
        close_io(pipe_set.ready_writer)
      end
      (pids - detached_pids).each { Process.detach(it) }
      raise
    end

    def worker_process(index, pipe_sets)
      own_pipe_set = pipe_sets.fetch(index)
      pipe_sets.each_with_index do |pipe_set, pipe_index|
        if pipe_index == index
          pipe_set.request_writer.close
          pipe_set.ready_reader.close
        else
          pipe_set.request_reader.close
          pipe_set.request_writer.close
          pipe_set.ready_reader.close
          pipe_set.ready_writer.close
        end
      end

      worker_loop(own_pipe_set.request_reader, own_pipe_set.ready_writer)
      exit!(0)
    rescue EOFError, Errno::EPIPE
      exit!(0)
    rescue Exception => e
      warn("urpc process pool worker failed: #{e.class}: #{e.message}")
      exit!(1)
    end

    def worker_loop(request_io, ready_io)
      loop do
        Urpc::ProcessIpc.write_ready(ready_io)
        bytes = Urpc::ProcessIpc.read_message(request_io)
        return if !bytes

        execute(Urpc::SubmitReader::Accepted.new(bytes: bytes.freeze))
      end
    end

  end
end
