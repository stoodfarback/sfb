# frozen_string_literal: true

require_relative("test_helper")

class UrpcClientTest < Minitest::Test
  def test_transport_error_rescues_client_transport_failures_only
    assert_equal(:transport, classify_error(Urpc::NoServerError.new))
    assert_equal(:transport, classify_error(Urpc::TimeoutException.new))
    assert_equal(:transport, classify_error(Urpc::ServerDisconnected.new))
    assert_equal(:other, classify_error(Urpc::RemoteException.new("remote failure")))
    assert_equal(:other, classify_error(Urpc::ClientDisconnected.new))
    assert_equal(:other, classify_error(RuntimeError.new))
  end

  def test_default_timeout_is_unbounded
    client = Urpc::Client.new("svc")

    assert_equal(0, client.timeout)
  end

  def test_rejects_invalid_timeout_during_construction
    invalid_values = [nil, true, "1", -1, Float::NAN, Float::INFINITY, Complex(1, 1)]

    invalid_values.each do |value|
      error = assert_raises(ArgumentError) { Urpc::Client.new("svc", timeout: value) }
      assert_equal("invalid urpc timeout: #{value.inspect}", error.message)
    end
  end

  def test_accepts_finite_nonnegative_numeric_timeouts
    [0, 0.5, Rational(1, 2)].each do |value|
      assert_equal(value, Urpc::Client.new("svc", timeout: value).timeout)
    end
  end

  def test_rejects_invalid_wait_for_server_during_construction
    invalid_values = [nil, "1", -1, Float::NAN, Float::INFINITY, Complex(1, 1)]

    invalid_values.each do |value|
      error = assert_raises(ArgumentError) { Urpc::Client.new("svc", wait_for_server: value) }
      assert_equal("invalid wait_for_server: #{value.inspect}", error.message)
    end
  end

  def test_accepts_supported_wait_for_server_values
    [false, true, 0, 0.5, Rational(1, 2)].each do |value|
      assert_equal(value, Urpc::Client.new("svc", wait_for_server: value).wait_for_server)
    end
  end

  def test_stream_submits_inline_request_and_reads_events
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      stream = client.stream(:watch, "key")
      submit = server.read_submit

      assert_equal(:watch, submit.request.name)
      assert_equal(["key"], submit.request.args)
      assert_equal({}, submit.request.kargs)
      assert_equal(true, submit.header.inline?)
      assert_equal(false, submit.header.cast?)

      output = server.open_output(submit.header.id)
      output.write_frame(:data, "one")
      output.write_frame(:return, "done")

      assert_equal(["one"], stream.to_a)
      assert_equal("done", stream.result)
    end
  end

  def test_call_waits_for_terminal_result
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)
      result_thread = Thread.new { client.call(:echo, "hello") }
      submit = server.read_submit
      output = server.open_output(submit.header.id)

      output.write_frame(:return, submit.request.args.first)

      assert_equal(:echo, submit.request.name)
      assert_equal("hello", result_thread.value)
    ensure
      result_thread.join if result_thread
    end
  end

  def test_method_missing_calls_rpc_method
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)
      result_thread = Thread.new { client.get_secret(project_name: "proj", secret_name: "api_key") }
      submit = server.read_submit
      output = server.open_output(submit.header.id)

      output.write_frame(:return, "secret")

      assert_equal(:get_secret, submit.request.name)
      assert_equal([], submit.request.args)
      assert_equal({ project_name: "proj", secret_name: "api_key" }, submit.request.kargs)
      assert_equal("secret", result_thread.value)
    ensure
      result_thread.join if result_thread
    end
  end

  def test_cast_submits_without_output_fifo
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      assert_nil(client.cast(:log, "event"))
      submit = server.read_submit

      assert_equal(:log, submit.request.name)
      assert_equal(true, submit.header.cast?)
      assert_equal(false, File.exist?(server.paths.output_fifo(submit.header.id)))
      assert_equal(false, File.exist?(server.paths.input_fifo(submit.header.id)))
    end
  end

  def test_cast_drops_when_no_server_is_ready
    with_urpc_root do
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      assert_nil(client.cast(:log, "event"))
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_stream_raises_no_server_without_creating_artifacts
    with_urpc_root do
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      assert_raises(Urpc::NoServerError) { client.stream(:watch) }
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_rejects_empty_method_name_without_creating_artifacts
    with_urpc_root do
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      nil_error = assert_raises(ArgumentError) { client.call(nil) }
      empty_error = assert_raises(ArgumentError) { client.call("") }

      assert_equal("invalid urpc method name: nil", nil_error.message)
      assert_equal('invalid urpc method name: ""', empty_error.message)
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_file_backed_submit_writes_payload_file
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)
      large_payload = "x" * Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX

      assert_nil(client.cast(:big, large_payload))
      submit = server.read_submit

      assert_equal(false, submit.header.inline?)
      assert_equal(["big", [large_payload], {}], MessagePack.unpack(submit.payload))
      assert_equal(false, File.exist?(server.paths.output_fifo(submit.header.id)))
    end
  end

  def test_bidirectional_submits_input_fifo_and_communicates
    with_server do |server|
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)
      stream = client.bidirectional(:chat)
      submit = server.read_submit

      assert_equal(true, submit.header.bidirectional?)
      assert(File.lstat(server.paths.input_fifo(submit.header.id)).pipe?)

      output = server.open_output(submit.header.id)
      input = server.open_input(submit.header.id)
      output.write_frame(:input_ready)

      assert_nil(stream.send_sync("hello"))
      output.write_frame(:data, "world")
      output.write_frame(:return, "done")

      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), input.next_frame)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: "hello"), input.next_frame)
      assert_equal(["world"], stream.to_a)
      assert_equal("done", stream.result)
    end
  end

  def test_rejects_blocks_before_submit
    with_urpc_root do
      client = Urpc::Client.new("svc", timeout: 1, wait_for_server: false)

      assert_raises(ArgumentError) { client.call(:echo) { "block" } }
      assert_raises(ArgumentError) { client.echo { "block" } }
    end
  end

  Submit = Data.define(:header, :payload, :request)

  class TestServer
    attr_accessor(:paths, :submit_io, :resources)

    def initialize(key)
      self.paths = Urpc::ServiceDir.new(key).prepare!
      self.submit_io = File.open(paths.submit_fifo, File::RDWR | File::NONBLOCK)
      self.resources = []
    end

    def read_submit
      header_bytes = read_exact(submit_io, Urpc::SubmitFrame::HEADER_BYTES)
      header = Urpc::SubmitFrame.unpack_header(header_bytes)
      payload =
        if header.inline?
          read_exact(submit_io, header.payload_len)
        else
          File.binread(paths.call_file(header.id))
        end

      Submit.new(header:, payload:, request: Urpc::SubmitFrame.unpack_request(payload))
    end

    def open_output(id)
      io = File.open(paths.output_fifo(id), File::WRONLY | File::NONBLOCK)
      File.unlink(paths.output_fifo(id))
      writer = Urpc::FrameWriter.new(io)
      resources << writer
      writer
    end

    def open_input(id)
      reader = Urpc::FrameReader.new(File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK), timeout: 1)
      resources << reader
      reader
    end

    def read_exact(io, bytesize)
      out = String.new(encoding: Encoding::BINARY)
      while out.bytesize < bytesize
        readable = io.wait_readable(1)
        if !readable
          raise("timed out reading submit frame")
        end

        chunk = io.read_nonblock(bytesize - out.bytesize, exception: false)
        if chunk == :wait_readable
          next
        end
        if chunk.nil?
          raise(EOFError, "submit fifo ended")
        end

        out << chunk
      end
      out
    end

    def close
      resources.reverse_each do |resource|
        if !resource.closed?
          resource.close
        end
      end
      if !submit_io.closed?
        submit_io.close
      end
    end

    def closed?
      submit_io.closed?
    end
  end

  def classify_error(error)
    raise(error)
  rescue Urpc::TransportError
    :transport
  rescue
    :other
  end

  def with_server
    with_urpc_root do
      server = TestServer.new("svc")
      yield(server)
    ensure
      close_io(server)
    end
  end
end
