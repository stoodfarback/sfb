# frozen_string_literal: true

require_relative("test_helper")

class UrpcFrameWriterTest < Minitest::Test
  def test_writes_payload_frame
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    reader = Urpc::FrameReader.new(input, timeout: 1)

    bytes_written = writer.write_frame(:data, "hello")

    assert_equal(Urpc::StreamFrame.pack(:data, "hello").bytesize, bytes_written)
    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: "hello"), reader.next_frame)
  ensure
    close_io(reader)
    close_io(writer)
  end

  def test_writes_no_payload_frame
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    reader = Urpc::FrameReader.new(input, timeout: 1)

    writer.write_frame(:input_ready)

    assert_equal(Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil), reader.next_frame)
  ensure
    close_io(reader)
    close_io(writer)
  end

  def test_loops_until_large_frame_is_written
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    reader = Urpc::FrameReader.new(input, timeout: 1)
    payload = "x" * (256 * 1024)

    writer_thread = Thread.new do
      writer.write_frame(:data, payload)
    end

    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: payload), reader.next_frame)
    assert_equal(Urpc::StreamFrame.pack(:data, payload).bytesize, writer_thread.value)
  ensure
    if writer_thread
      writer_thread.join
    end
    close_io(reader)
    close_io(writer)
  end

  def test_serializes_concurrent_large_frames
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    reader = Urpc::FrameReader.new(input, timeout: 2)
    start = Thread::Queue.new
    payloads = ["a" * (256 * 1024), "b" * (256 * 1024)]
    writer_threads = payloads.map do |payload|
      Thread.new do
        start.pop
        writer.write_frame(:sync, payload)
      end
    end
    writer_threads.size.times { start << true }

    frames = writer_threads.size.times.map { reader.next_frame }

    assert_equal([:sync, :sync], frames.map(&:type))
    assert_equal(payloads.sort, frames.map(&:value).sort)
    writer_threads.each(&:value)
  ensure
    close_io(reader)
    writer_threads&.each do |thread|
      thread.join(1)
      thread.kill if thread.alive?
    end
    close_io(writer)
  end

  def test_surfaces_epipe
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    input.close

    assert_raises(Errno::EPIPE) { writer.write_frame(:return, "done") }
  ensure
    close_io(input)
    close_io(writer)
  end

  def test_delegates_pack_validation
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)

    assert_raises(ArgumentError) { writer.write_frame(:data) }
    assert_raises(ArgumentError) { writer.write_frame(:ready, nil) }
  ensure
    close_io(input)
    close_io(writer)
  end

  def test_close
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)

    writer.close

    assert(writer.closed?)
  ensure
    close_io(input)
    close_io(writer)
  end
end
