# frozen_string_literal: true

require_relative("test_helper")

class UrpcSubmitWriterTest < Minitest::Test
  def test_wait_false_does_not_prepare_service_dir
    with_urpc_root do
      error = assert_raises(Urpc::NoServerError) { Urpc::SubmitWriter.open("svc", wait_for_server: false) }

      assert_match(/no urpc server/, error.message)
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_wait_false_opens_existing_submit_fifo_without_preparing
    with_urpc_root do
      service = Urpc::ServiceDir.new("svc")
      paths = service.prepare!
      reader = File.open(paths.submit_fifo, File::RDONLY | File::NONBLOCK)
      writer = Urpc::SubmitWriter.open("svc", wait_for_server: false)

      assert_equal(3, writer.write("abc"))
      assert(reader.wait_readable(1))
      assert_equal("abc", reader.read_nonblock(3))
    ensure
      close_io(writer)
      close_io(reader)
    end
  end

  def test_numeric_zero_matches_false_without_preparing_service_dir
    with_urpc_root do
      error = assert_raises(Urpc::NoServerError) { Urpc::SubmitWriter.open("svc", wait_for_server: 0) }

      assert_match(/no urpc server/, error.message)
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_numeric_wait_retries_until_reader_exists
    with_urpc_root do
      paths = Urpc::Paths.new("svc")
      reader_thread = open_reader_when_submit_fifo_exists(paths)

      writer = Urpc::SubmitWriter.open("svc", wait_for_server: 1)
      reader = reader_thread.value

      assert_equal(3, writer.write("abc"))
      assert(reader.wait_readable(1))
      assert_equal("abc", reader.read_nonblock(3))
    ensure
      close_io(writer)
      close_io(reader)
    end
  end

  def test_true_wait_prepares_fifo_then_uses_blocking_open
    with_urpc_root do
      paths = Urpc::Paths.new("svc")
      reader_thread = open_reader_when_submit_fifo_exists(paths)

      writer = Urpc::SubmitWriter.open("svc", wait_for_server: true)
      reader = reader_thread.value

      assert_equal(3, writer.write("abc"))
      assert(reader.wait_readable(1))
      assert_equal("abc", reader.read_nonblock(3))
    ensure
      close_io(writer)
      close_io(reader)
    end
  end

  def test_invalid_wait_value
    with_urpc_root do
      invalid_values = [nil, "1", -1, Float::NAN, Float::INFINITY, Complex(1, 1)]

      invalid_values.each do |value|
        error = assert_raises(ArgumentError) { Urpc::SubmitWriter.open("svc", wait_for_server: value) }
        assert_equal("invalid wait_for_server: #{value.inspect}", error.message)
      end
      assert_equal(false, File.exist?(File.join(Urpc.root, "svc")))
    end
  end

  def test_write_raises_no_server_when_reader_disconnects
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      reader = File.open(paths.submit_fifo, File::RDONLY | File::NONBLOCK)
      writer = Urpc::SubmitWriter.open("svc", wait_for_server: false)
      reader.close

      error = assert_raises(Urpc::NoServerError) { writer.write("abc") }

      assert_match(/submit failed|not writable/, error.message)
    ensure
      close_io(writer)
      close_io(reader)
    end
  end

  def test_write_rejects_frames_larger_than_atomic_budget
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      reader = File.open(paths.submit_fifo, File::RDONLY | File::NONBLOCK)
      writer = Urpc::SubmitWriter.open("svc", wait_for_server: false)

      assert_raises(ArgumentError) { writer.write("x" * (Urpc::SubmitFrame::ATOMIC_WRITE_BYTES + 1)) }
    ensure
      close_io(writer)
      close_io(reader)
    end
  end

  def open_reader_when_submit_fifo_exists(paths)
    Thread.new do
      until File.exist?(paths.submit_fifo)
        sleep(0.001)
      end

      File.open(paths.submit_fifo, File::RDONLY | File::NONBLOCK)
    end
  end
end
