# frozen_string_literal: true

require_relative("test_helper")

class UrpcExecutorProcessPerRequestTest < Minitest::Test
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

  class ExitRequest < Urpc::Handler
    def call
      exit!(17)
    end
  end

  def test_each_call_runs_in_a_fresh_process
    with_process_server(worker_info: WorkerInfo) do |client, executor|
      first_pid = client.call(:worker_info)
      second_pid = client.call(:worker_info)

      refute_equal(first_pid, second_pid)
      refute_equal(Process.pid, first_pid)
      refute_equal(executor.forker_pid, first_pid)
      refute_equal(executor.forker_pid, second_pid)
    end
  end

  def test_calls_run_concurrently
    with_process_server(worker_info: WorkerInfo) do |client|
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      first = Thread.new { client.call(:worker_info, delay: 0.2) }
      second = Thread.new { client.call(:worker_info, delay: 0.2) }
      pids = [first.value, second.value]
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      refute_equal(pids.first, pids.last)
      assert_operator(elapsed, :<, 0.35)
    ensure
      first&.join
      second&.join
    end
  end

  def test_file_backed_request_is_hydrated_in_request_process
    with_process_server(payload_size: PayloadSize) do |client|
      payload = "x" * Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX

      assert_equal(payload.bytesize, client.call(:payload_size, payload))
    end
  end

  def test_forker_does_not_retain_service_lock
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(worker_info: WorkerInfo)
      executor = Urpc::Executor::ProcessPerRequest.new
      server = Urpc::Server.new("svc", executor:, &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 2)

      client.call(:worker_info)
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

  def test_request_child_death_does_not_stop_forker
    with_process_server(exit_request: ExitRequest, worker_info: WorkerInfo) do |client|
      assert_raises(Urpc::ServerDisconnected) { client.call(:exit_request) }

      worker_pid = client.call(:worker_info)
      refute_equal(Process.pid, worker_pid)
    end
  end

  def with_process_server(**handlers)
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(**handlers)
      executor = Urpc::Executor::ProcessPerRequest.new
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
