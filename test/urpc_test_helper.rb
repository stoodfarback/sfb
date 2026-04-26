# frozen_string_literal: true

require("sfb")
require("minitest/mock")
require("minitest/autorun")

class Minitest::Test
  def with_root(&)
    Dir.mktmpdir("urpc-") do |tmpdir|
      orig_root = Urpc.root
      orig_env = ENV["URPC_ROOT"]
      orig_stdout = $stdout
      orig_stderr = $stderr
      begin
        Urpc.set_root(tmpdir)
        ENV["URPC_ROOT"] = tmpdir
        $stdout = StringIO.new
        $stderr = StringIO.new
        yield
      ensure
        $stdout = orig_stdout
        $stderr = orig_stderr
        Urpc.set_root(orig_root)
        ENV["URPC_ROOT"] = orig_env
      end
    end
  end

  def poll_until
    end_at = Time.now + 5
    while Time.now < end_at
      return(true) if yield
      sleep(0.01)
    end
    false
  end

  def wait_for_broker
    raise("broker did not start") if !poll_until { File.socket?(Urpc.broker_sock) && File.pipe?(Urpc.submit_fifo) }
  end

  def wait_for_backend(rpc_key, count: 1)
    raise("backend did not register for #{rpc_key}") if !poll_until { @broker.backend_count(rpc_key) >= count }
  end

  def start_server(rpc_key, handler)
    server = Urpc::Server.new(rpc_key, handler)
    thread = Thread.new { server.run }
    thread.report_on_exception = false
    @server_threads << thread
    server
  end

  def start_stream_server(rpc_key, handler)
    server = Urpc::StreamServer.new(rpc_key, handler)
    thread = Thread.new { server.run }
    thread.report_on_exception = false
    @server_threads << thread
    server
  end

  def spawn_broker
    bin = File.expand_path("../bin/urpc-broker", __dir__)
    Process.spawn(bin, out: "/dev/null", err: "/dev/null")
  end

  def teardown_process(pid)
    return if !pid
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  def with_broker(&)
    with_root do
      @broker = Urpc::Broker.new
      @broker_thread = Thread.new { @broker.run }
      @broker_thread.report_on_exception = false
      @server_threads = []

      wait_for_broker

      begin
        yield
      ensure
        @server_threads.each { it.kill rescue nil }
        @broker.stop
        @broker_thread.kill rescue nil
      end
    end
  end
end
