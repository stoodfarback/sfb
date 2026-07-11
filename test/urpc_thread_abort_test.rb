# frozen_string_literal: true

require_relative("test_helper")

class UrpcThreadAbortTest < Minitest::Test
  PROJECT_ROOT = File.expand_path("..", __dir__)

  def test_thread_pool_uncaught_exception_aborts_process
    assert_thread_error_aborts_process("thread pool failed", <<~'RUBY')
      Dir.mktmpdir do |dir|
        Urpc.set_root(dir)
        started = Thread::Queue.new
        executor = Urpc::Executor::ThreadPool.new(size: 1)
        server = Urpc::Server.new("svc", executor:) do
          started << true
          raise(NotImplementedError, "thread pool failed")
        end
        Thread.new { server.run }
        Urpc::Client.new("svc").cast(:boom)
        started.pop
        sleep(0.1)
      end
    RUBY
  end

  def test_thread_per_request_uncaught_exception_aborts_process
    assert_thread_error_aborts_process("thread per request failed", <<~'RUBY')
      Dir.mktmpdir do |dir|
        Urpc.set_root(dir)
        started = Thread::Queue.new
        executor = Urpc::Executor::ThreadPerRequest.new
        server = Urpc::Server.new("svc", executor:) do
          started << true
          raise(NotImplementedError, "thread per request failed")
        end
        Thread.new { server.run }
        Urpc::Client.new("svc").cast(:boom)
        started.pop
        sleep(0.1)
      end
    RUBY
  end

  def test_bidirectional_input_reader_uncaught_exception_aborts_process
    assert_thread_error_aborts_process("must implement #receive_async", <<~'RUBY')
      id = Urpc::Id.from_hex("0123456789abcdef")
      header = Urpc::SubmitFrame::Header.new(flags: Urpc::SubmitFrame::BIDIRECTIONAL, id:, payload_len: 0)
      request = Urpc::SubmitFrame::Request.new(name: :chat, args: [], kargs: {})
      submit = Urpc::SubmitReader::Submit.new(header:, payload: "", request:)
      call = Urpc::ServerCall.new(Urpc::Paths.new("svc"), submit)
      input_reader, input_writer = IO.pipe
      call.input_reader = Urpc::FrameReader.new(input_reader, timeout: 1)
      req = Urpc::Req.new(call)
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        def call = nil
      end
      handler = handler_class.new(req)
      handler.input.start
      Urpc::FrameWriter.new(input_writer).write_frame(:async, :unexpected)
      sleep(0.1)
    RUBY
  end

  def assert_thread_error_aborts_process(message, script)
    _stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-I#{File.join(PROJECT_ROOT, "lib")}",
      "-rsfb",
      "-e",
      script,
      chdir: PROJECT_ROOT,
    )

    assert_equal(false, status.success?)
    assert_includes(stderr, "NotImplementedError")
    assert_includes(stderr, message)
  end
end
