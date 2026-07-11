# frozen_string_literal: true

require_relative("test_helper")

class UrpcServerCallTest < Minitest::Test
  def test_cast_call_has_no_stream_fds
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit(cast: true)

      call = Urpc::ServerCall.open(paths, submit)

      assert_equal(true, call.cast?)
      assert_nil(call.output)
      assert_nil(call.input_reader)
      assert_equal(true, call.closed?)
    end
  end

  def test_opens_output_and_unlinks_rendezvous_path
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      client_reader = Urpc::FrameReader.new(File.open(paths.output_fifo(submit.id), File::RDONLY | File::NONBLOCK), timeout: 1)

      call = Urpc::ServerCall.open(paths, submit)

      assert(File.lstat(paths.dir).directory?)
      assert_equal(false, File.exist?(paths.output_fifo(submit.id)))
      call.output.write_frame(:return, "ok")
      assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "ok"), client_reader.next_frame)
    ensure
      close_io(call)
      close_io(client_reader)
    end
  end

  def test_drops_when_output_reader_is_missing
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit(bidirectional: true)
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      File.mkfifo(paths.input_fifo(submit.id), 0o600)

      call = Urpc::ServerCall.open(paths, submit)

      assert_nil(call)
      assert_equal(false, File.exist?(paths.output_fifo(submit.id)))
      assert_equal(false, File.exist?(paths.input_fifo(submit.id)))
    end
  end

  def test_bidirectional_call_writes_input_ready_and_reads_ready
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit(bidirectional: true)
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      File.mkfifo(paths.input_fifo(submit.id), 0o600)
      output_reader = Urpc::FrameReader.new(File.open(paths.output_fifo(submit.id), File::RDONLY | File::NONBLOCK), timeout: 1)
      server_thread = Thread.new { Urpc::ServerCall.open(paths, submit) }

      assert_equal(Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil), output_reader.next_frame)
      input = Urpc::InputStream.open(paths, id: submit.id)
      call = server_thread.value

      assert(call)
      assert_nil(call.input_reader.deadline)
      assert_equal(false, File.exist?(paths.output_fifo(submit.id)))
      assert_equal(false, File.exist?(paths.input_fifo(submit.id)))

      input.send_sync("hello")
      assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: "hello"), call.input_reader.next_frame)
    ensure
      server_thread.join if server_thread
      close_io(call)
      close_io(input)
      close_io(output_reader)
    end
  end

  def test_bidirectional_call_drops_if_client_closes_before_ready
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit(bidirectional: true)
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      File.mkfifo(paths.input_fifo(submit.id), 0o600)
      output_reader = Urpc::FrameReader.new(File.open(paths.output_fifo(submit.id), File::RDONLY | File::NONBLOCK), timeout: 1)
      server_thread = Thread.new { Urpc::ServerCall.open(paths, submit) }

      assert_equal(Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil), output_reader.next_frame)
      input_io = File.open(paths.input_fifo(submit.id), File::WRONLY | File::NONBLOCK)
      File.unlink(paths.input_fifo(submit.id))
      input_io.close
      call = server_thread.value

      assert_nil(call)
    ensure
      server_thread.join if server_thread
      close_io(output_reader)
      close_io(input_io)
    end
  end

  def test_unexpected_input_frame_is_protocol_error
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit(bidirectional: true)
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      File.mkfifo(paths.input_fifo(submit.id), 0o600)
      output_reader = Urpc::FrameReader.new(File.open(paths.output_fifo(submit.id), File::RDONLY | File::NONBLOCK), timeout: 1)
      server_thread = Thread.new { Urpc::ServerCall.open(paths, submit) }

      assert_equal(Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil), output_reader.next_frame)
      input_io = File.open(paths.input_fifo(submit.id), File::WRONLY | File::NONBLOCK)
      File.unlink(paths.input_fifo(submit.id))
      Urpc::FrameWriter.new(input_io).write_frame(:sync, "too soon")

      error = assert_raises(RuntimeError) { server_thread.value }

      assert_match(/expected READY/, error.message)
    ensure
      server_thread.join if server_thread&.alive?
      close_io(output_reader)
      close_io(input_io)
    end
  end

  def test_close_closes_open_fds
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submit = build_submit
      File.mkfifo(paths.output_fifo(submit.id), 0o600)
      client_reader = Urpc::FrameReader.new(File.open(paths.output_fifo(submit.id), File::RDONLY | File::NONBLOCK), timeout: 1)
      call = Urpc::ServerCall.open(paths, submit)

      call.close

      assert(call.closed?)
    ensure
      close_io(call)
      close_io(client_reader)
    end
  end

  def build_submit(cast: false, bidirectional: false)
    id = Urpc::Id.from_hex("0123456789abcdef")
    flags = 0
    if cast
      flags |= Urpc::SubmitFrame::CAST
    end
    if bidirectional
      flags |= Urpc::SubmitFrame::BIDIRECTIONAL
    end
    header = Urpc::SubmitFrame::Header.new(flags:, id:, payload_len: 0)
    request = Urpc::SubmitFrame::Request.new(name: :call, args: [], kargs: {})
    Urpc::SubmitReader::Submit.new(header:, payload: "", request:)
  end
end
