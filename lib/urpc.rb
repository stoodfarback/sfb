# frozen_string_literal: true

module Urpc
  autoload(:Bidirectional, "urpc/bidirectional")
  autoload(:BidirectionalHandler, "urpc/bidirectional_handler")
  autoload(:BidirectionalInput, "urpc/bidirectional_input")
  autoload(:CallArtifacts, "urpc/call_artifacts")
  autoload(:CliCommand, "urpc/cli_command")
  autoload(:CliSession, "urpc/cli_session")
  autoload(:Client, "urpc/client")
  autoload(:Deadline, "urpc/deadline")
  autoload(:Dispatch, "urpc/dispatch")
  autoload(:Executor, "urpc/executor")
  autoload(:Fifo, "urpc/fifo")
  autoload(:FrameReader, "urpc/frame_reader")
  autoload(:FrameWriter, "urpc/frame_writer")
  autoload(:Handler, "urpc/handler")
  autoload(:Id, "urpc/id")
  autoload(:InputStream, "urpc/input_stream")
  autoload(:Paths, "urpc/paths")
  autoload(:ProcessIpc, "urpc/process_ipc")
  autoload(:Req, "urpc/req")
  autoload(:RequestRunner, "urpc/request_runner")
  autoload(:Server, "urpc/server")
  autoload(:ServerCall, "urpc/server_call")
  autoload(:ServiceDir, "urpc/service_dir")
  autoload(:Stream, "urpc/stream")
  autoload(:StreamFrame, "urpc/stream_frame")
  autoload(:SubmitFrame, "urpc/submit_frame")
  autoload(:SubmitReader, "urpc/submit_reader")
  autoload(:SubmitWriter, "urpc/submit_writer")

  DEFAULT_ROOT = "/tmp/urpc2"

  class TransportError < StandardError; end
  class NoServerError < TransportError; end
  class TimeoutException < TransportError; end
  class ClientDisconnected < StandardError; end
  class ServerDisconnected < TransportError; end

  class RemoteException < StandardError
    attr_accessor(:remote_backtrace, :remote_exception)

    def initialize(message, remote_backtrace = [], remote_exception: nil)
      super(message)
      self.remote_backtrace = remote_backtrace
      self.remote_exception = remote_exception
    end
  end

  class << self
    attr_accessor(:configured_root)
  end

  def self.root
    configured_root || ENV["URPC_ROOT"] || DEFAULT_ROOT
  end

  def self.set_root(path)
    self.configured_root = path.to_s.freeze
  end
end
