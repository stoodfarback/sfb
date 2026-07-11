# frozen_string_literal: true

require_relative("test_helper")

class UrpcExecutorProcessPoolTest < Minitest::Test
  class WorkerInfo < Urpc::Handler
    def call(delay: 0)
      sleep(delay)
      Process.pid
    end
  end

  class PayloadSize < Urpc::Handler
    def call(payload)
      payload.bytesize
    end
  end

  class ExitWorker < Urpc::Handler
    def call
      exit!(17)
    end
  end

  def test_concurrent_calls_run_in_distinct_worker_processes
    with_process_pool(size: 2, worker_info: WorkerInfo) do |client, executor|
      first = Thread.new { client.call(:worker_info, delay: 0.05) }
      second = Thread.new { client.call(:worker_info, delay: 0.05) }
      worker_pids = [first.value, second.value]

      assert_equal(2, worker_pids.uniq.size)
      refute_includes(worker_pids, Process.pid)
      assert_equal(executor.workers.map(&:pid).sort, worker_pids.sort)
    ensure
      first&.join
      second&.join
    end
  end

  def test_file_backed_request_is_hydrated_in_worker
    with_process_pool(size: 1, payload_size: PayloadSize) do |client|
      payload = "x" * Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX

      assert_equal(payload.bytesize, client.call(:payload_size, payload))
    end
  end

  def test_workers_do_not_retain_service_lock
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(worker_info: WorkerInfo)
      executor = Urpc::Executor::ProcessPool.new(size: 1)
      server = Urpc::Server.new("svc", executor:, &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 2)
      worker_pid = client.call(:worker_info)

      assert_includes(executor.workers.map(&:pid), worker_pid)
      server.close
      server_thread.join(1)

      replacement = Urpc::Server.new("svc") { |req| req.finish("replacement") }
      assert(replacement)
    ensure
      close_io(server)
      server_thread&.kill if server_thread&.alive?
      close_io(replacement)
    end
  end

  def test_worker_death_terminates_owner_run_loop
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(exit_worker: ExitWorker)
      executor = Urpc::Executor::ProcessPool.new(size: 1)
      server = Urpc::Server.new("svc", executor:, &dispatch)
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 1)
      stream = client.stream(:exit_worker)

      error = assert_raises(RuntimeError) { server_thread.value }

      assert_includes(error.message, "process pool worker")
    ensure
      close_io(stream)
      close_io(server)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def test_validates_configuration
    assert_raises(ArgumentError) { Urpc::Executor::ProcessPool.new(size: 0) }
  end

  def with_process_pool(size:, **handlers)
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(**handlers)
      executor = Urpc::Executor::ProcessPool.new(size:)
      server = Urpc::Server.new("svc", executor:, &dispatch)
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 2)

      yield(client, executor, server)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end
end
