# frozen_string_literal: true

module Urpc
  autoload(:Backend, "urpc/backend")
  autoload(:Broker, "urpc/broker")
  autoload(:Call, "urpc/call")
  autoload(:CliCall, "urpc/cli_call")
  autoload(:Client, "urpc/client")
  autoload(:Event, "urpc/event")
  autoload(:EventStream, "urpc/event_stream")
  autoload(:Frames, "urpc/frames")
  autoload(:InternalBackend, "urpc/internal_backend")
  autoload(:Introspection, "urpc/introspection")
  autoload(:MonitorSink, "urpc/monitor_sink")
  autoload(:Req, "urpc/req")
  autoload(:ResponseStream, "urpc/response_stream")
  autoload(:Server, "urpc/server")
  autoload(:StreamServer, "urpc/stream_server")
  autoload(:Util, "urpc/util")

  DEFAULT_ROOT = "/tmp/urpc"

  def self.root
    @root ||= (ENV["URPC_ROOT"]&.dup || DEFAULT_ROOT).freeze
  end

  def self.set_root(path)
    @root = path.to_s.freeze
  end

  def self.broker_sock = File.join(root, "broker.sock")
  def self.monitor_sock = File.join(root, "monitor.sock")
  def self.submit_fifo = File.join(root, "submit.fifo")
  def self.requests_dir = File.join(root, "requests")
  def self.replies_dir = File.join(root, "replies")

  ID_RE = /\A[a-f0-9]{32}\z/
  RESERVED_KEY = "urpc"

  class BrokerUnavailable < StandardError; end
  class NoServerError < StandardError; end
  class TimeoutException < StandardError; end

  class RemoteException < StandardError
    attr_accessor(:remote_backtrace)

    def initialize(message, remote_backtrace = [])
      super(message)
      self.remote_backtrace = remote_backtrace
    end
  end

  def self.run_broker
    Process.setproctitle("[sfb_urpc] #{ARGV.join(" ")}")
    broker = Broker.new

    Signal.trap("TERM") { broker.shutdown = true }
    Signal.trap("INT") { broker.shutdown = true }

    begin
      broker.run
    ensure
      broker.stop
    end
  end

  def self.run_call
    CliCall.run
  end
end
