# frozen_string_literal: true

require_relative("test_helper")

module UrpcProcessExecutorParityTests
  class Chat < Urpc::BidirectionalHandler
    def call
      pid = Process.pid
      data(pid)
      [pid, receive]
    end
  end

  class StreamError < Urpc::Handler
    def call
      data("before error")
      raise(ArgumentError, "stream failed")
    end
  end

  def test_bidirectional_call
    with_process_server(chat: Chat) do |client|
      stream = client.bidirectional(:chat)

      assert_nil(stream.send_sync("hello"))
      worker_pid = stream.to_a.fetch(0)
      assert_equal([worker_pid, "hello"], stream.result)
      refute_equal(Process.pid, worker_pid)
    end
  end

  def test_streamed_data_precedes_terminal_error
    with_process_server(stream_error: StreamError) do |client|
      stream = client.stream(:stream_error)
      values = stream.each

      assert_equal("before error", values.next)
      error = assert_raises(ArgumentError) { values.next }
      assert_equal("stream failed", error.message)
      repeated_error = assert_raises(ArgumentError) { stream.result }
      assert_same(error, repeated_error)
    end
  end

  def test_cast_executes_in_request_process
    with_urpc_root do
      result_path = File.join(Urpc.root, "cast-result")
      handler_class = Class.new(Urpc::Handler)
      handler_class.define_method(:call) do |value|
        File.write(result_path, "#{Process.pid}:#{value}")
      end

      with_process_server(write_result: handler_class, nested_root: false) do |client|
        assert_nil(client.cast(:write_result, "done"))
        wait_for_file(result_path)
        pid, value = File.read(result_path).split(":", 2)

        refute_equal(Process.pid, pid.to_i)
        assert_equal("done", value)
      end
    end
  end

  def test_active_executor_does_not_retain_service_lock
    with_urpc_root do
      gate_reader, gate_writer = IO.pipe
      handler_class = Class.new(Urpc::Handler)
      handler_class.define_method(:call) do
        data(Process.pid)
        gate_reader.read(1)
        "finished"
      end

      dispatch = Urpc::Dispatch.new(wait: handler_class)
      server = build_process_server(dispatch)
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 2)
      stream = client.stream(:wait)
      worker_pid = stream.each.next

      refute_equal(Process.pid, worker_pid)
      server.close
      server_thread.join(1)

      replacement = Urpc::Server.new("svc") { |req| req.finish("replacement") }
      assert(replacement)

      gate_writer.write("x")
      assert_equal("finished", stream.result)
    ensure
      close_io(server)
      server_thread&.kill if server_thread&.alive?
      close_io(replacement)
      close_io(gate_reader)
      close_io(gate_writer)
      close_io(stream)
    end
  end

  def test_client_disconnect_abandons_only_that_request
    with_urpc_root do
      gate_reader, gate_writer = IO.pipe
      handler = proc do |req|
        if req.name == :disconnect
          req.data("first")
          gate_reader.read(1)
          req.data("second")
        else
          req.finish("pong")
        end
      end

      server = build_raw_process_server(handler)
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 2)
      stream = client.stream(:disconnect)
      values = stream.each

      assert_equal("first", values.next)
      stream.close
      gate_writer.write("x")

      assert_equal("pong", client.call(:ping))
    ensure
      close_io(stream)
      close_io(server)
      close_io(gate_reader)
      close_io(gate_writer)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def with_process_server(nested_root: true, **handlers)
    runner = proc do
      dispatch = Urpc::Dispatch.new(**handlers)
      server = build_process_server(dispatch)
      server_thread = Thread.new { server.run }
      server_thread.report_on_exception = false
      client = Urpc::Client.new("svc", timeout: 2)

      yield(client, server)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end

    if nested_root
      with_urpc_root(&runner)
    else
      runner.call
    end
  end

  def build_process_server(dispatch)
    Urpc::Server.new("svc", executor: build_process_executor, &dispatch)
  end

  def build_raw_process_server(handler)
    Urpc::Server.new("svc", executor: build_process_executor, &handler)
  end

  def build_process_executor
    if self.class::EXECUTOR_CLASS == Urpc::Executor::ProcessPool
      self.class::EXECUTOR_CLASS.new(size: 2)
    else
      self.class::EXECUTOR_CLASS.new
    end
  end

  def wait_for_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return if File.exist?(path)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise("timed out waiting for #{path}")
      end
      sleep(0.005)
    end
  end
end

class UrpcProcessPoolParityTest < Minitest::Test
  EXECUTOR_CLASS = Urpc::Executor::ProcessPool
  include(UrpcProcessExecutorParityTests)
end

class UrpcProcessPerRequestParityTest < Minitest::Test
  EXECUTOR_CLASS = Urpc::Executor::ProcessPerRequest
  include(UrpcProcessExecutorParityTests)
end
