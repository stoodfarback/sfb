# frozen_string_literal: true

require_relative("test_helper")

class UrpcInputStreamTest < Minitest::Test
  def test_open_unlinks_input_path_and_writes_ready
    with_urpc_root do
      paths, id = prepare_input_fifo
      reader_io = File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK)
      reader = Urpc::FrameReader.new(reader_io, timeout: 1)

      input = Urpc::InputStream.open(paths, id:)

      assert_equal(false, File.exist?(paths.input_fifo(id)))
      assert_equal(true, input.open?)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), reader.next_frame)
    ensure
      close_io(input)
      close_io(reader)
    end
  end

  def test_send_sync_and_async_frames
    with_urpc_root do
      paths, id = prepare_input_fifo
      reader_io = File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK)
      reader = Urpc::FrameReader.new(reader_io, timeout: 1)
      input = Urpc::InputStream.open(paths, id:)
      reader.next_frame

      assert_nil(input.send_sync("question"))
      assert_nil(input.send_async({ cancel: true }))

      assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: "question"), reader.next_frame)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :async, value: { cancel: true }), reader.next_frame)
    ensure
      close_io(input)
      close_io(reader)
    end
  end

  def test_open_maps_missing_input_fifo_to_server_disconnected
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      id = Urpc::Id.from_hex("0123456789abcdef")

      error = assert_raises(Urpc::ServerDisconnected) { Urpc::InputStream.open(paths, id:) }

      assert_equal("urpc server disconnected before input attachment", error.message)
    end
  end

  def test_open_maps_no_reader_to_server_disconnected_and_keeps_path
    with_urpc_root do
      paths, id = prepare_input_fifo

      assert_raises(Urpc::ServerDisconnected) { Urpc::InputStream.open(paths, id:) }
      assert(File.lstat(paths.input_fifo(id)).pipe?)
    end
  end

  def test_open_rejects_non_fifo_path_without_unlinking
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      id = Urpc::Id.from_hex("0123456789abcdef")
      File.write(paths.input_fifo(id), "not a fifo")

      error = assert_raises(RuntimeError) { Urpc::InputStream.open(paths, id:) }

      assert_match(/not a FIFO/, error.message)
      assert_equal("not a fifo", File.read(paths.input_fifo(id)))
    end
  end

  def test_send_after_close_raises_io_error
    with_urpc_root do
      paths, id = prepare_input_fifo
      reader_io = File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK)
      reader = Urpc::FrameReader.new(reader_io, timeout: 1)
      input = Urpc::InputStream.open(paths, id:)

      input.close

      assert_equal(false, input.open?)
      assert_raises(IOError) { input.send_sync("question") }
    ensure
      close_io(input)
      close_io(reader)
    end
  end

  def test_send_surfaces_epipe
    with_urpc_root do
      paths, id = prepare_input_fifo
      reader_io = File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK)
      input = Urpc::InputStream.open(paths, id:)
      reader_io.close

      assert_raises(Errno::EPIPE) { input.send_sync("question") }
    ensure
      close_io(input)
      close_io(reader_io)
    end
  end

  def prepare_input_fifo
    paths = Urpc::ServiceDir.new("svc").prepare!
    id = Urpc::Id.from_hex("0123456789abcdef")
    Urpc::Fifo.create(paths.input_fifo(id))
    [paths, id]
  end
end
