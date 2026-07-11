# frozen_string_literal: true

require_relative("test_helper")

class UrpcFrameReaderTest < Minitest::Test
  def test_reads_frame
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 1)

    output.write(Urpc::StreamFrame.pack(:data, "hello"))

    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: "hello"), reader.next_frame)
  ensure
    close_io(reader)
    close_io(output)
  end

  def test_buffers_partial_frame_until_complete
    input, output = IO.pipe
    frame = Urpc::StreamFrame.pack(:return, "done")
    reader = Urpc::FrameReader.new(input, timeout: 1)
    writer = Thread.new do
      output.write(frame.byteslice(0, 2))
      sleep(0.01)
      output.write(frame.byteslice(2..))
    end

    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "done"), reader.next_frame)
  ensure
    writer.join if writer
    close_io(reader)
    close_io(output)
  end

  def test_returns_buffered_frames_before_waiting_again
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 1)

    output.write(Urpc::StreamFrame.pack(:input_ready) + Urpc::StreamFrame.pack(:return, nil))

    assert_equal(Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil), reader.next_frame)
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: nil), reader.next_frame)
  ensure
    close_io(reader)
    close_io(output)
  end

  def test_timeout_zero_means_no_deadline
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 0)
    writer = Thread.new do
      sleep(0.01)
      output.write(Urpc::StreamFrame.pack(:data, "late"))
    end

    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: "late"), reader.next_frame)
  ensure
    writer.join if writer
    close_io(reader)
    close_io(output)
  end

  def test_raises_call_timeout_when_no_frame_arrives_before_deadline
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 0.001)

    assert_raises(Urpc::TimeoutException) { reader.next_frame }
    assert(reader.closed?)
  ensure
    close_io(reader)
    close_io(output)
  end

  def test_deadline_is_absolute_across_frames
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 0.03)
    output.write(Urpc::StreamFrame.pack(:data, "first"))

    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: "first"), reader.next_frame)
    sleep(0.04)

    assert_raises(Urpc::TimeoutException) { reader.next_frame }
    assert(reader.closed?)
  ensure
    close_io(reader)
    close_io(output)
  end

  def test_returns_nil_on_clean_eof
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 1)
    output.write(Urpc::StreamFrame.pack(:ready))
    output.close

    assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), reader.next_frame)
    assert_nil(reader.next_frame)
  ensure
    close_io(reader)
    close_io(output)
  end

  def test_raises_eof_error_for_partial_frame_at_eof
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 1)
    frame = Urpc::StreamFrame.pack(:data, "hello")
    output.write(frame.byteslice(0, 3))
    output.close

    assert_raises(EOFError) { reader.next_frame }
  ensure
    close_io(reader)
    close_io(output)
  end
end
