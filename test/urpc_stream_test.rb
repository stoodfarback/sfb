# frozen_string_literal: true

require_relative("test_helper")

class UrpcStreamTest < Minitest::Test
  def test_each_enumerator_returns_data_and_stops_at_terminal_frame
    stream, writer = stream_pair
    values = stream.each

    writer.write_frame(:data, "one")
    writer.write_frame(:data, nil)
    writer.write_frame(:return, "done")

    assert_equal("one", values.next)
    assert_equal(false, stream.finished?)
    assert_nil(values.next)
    assert_equal(false, stream.finished?)
    assert_raises(StopIteration) { values.next }
    assert_equal(true, stream.finished?)
    assert_equal("done", stream.result)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_each_yields_nil_data_and_stops_on_return
    stream, writer = stream_pair

    writer.write_frame(:data, "one")
    writer.write_frame(:data, nil)
    writer.write_frame(:return, "done")

    values = stream.to_a

    assert_equal(["one", nil], values)
    assert_equal(true, stream.finished?)
    assert_equal("done", stream.result)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_result_drains_stream_and_returns_terminal_value
    stream, writer = stream_pair

    writer.write_frame(:data, "ignored")
    writer.write_frame(:return, 123)

    assert_equal(123, stream.result)
    assert_equal(true, stream.finished?)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_error_frame_raises_original_exception_class
    stream, writer = stream_pair
    error_payload = ["ArgumentError", "bad input", ["remote.rb:1"]]

    writer.write_frame(:error, error_payload)

    error = assert_raises(ArgumentError) { stream.each.next }
    assert_equal("bad input", error.message)
    assert_equal(["remote.rb:1"], error.backtrace)
    assert_equal(true, stream.finished?)
    assert_raises(ArgumentError) { stream.result }
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_error_frame_uses_remote_exception_for_unknown_exception_class
    stream, writer = stream_pair
    error_payload = ["MissingRemoteError", "bad input", ["remote.rb:1"]]

    writer.write_frame(:error, error_payload)

    error = assert_raises(Urpc::RemoteException) { stream.each.next }
    assert_equal("MissingRemoteError: bad input", error.message)
    assert_equal("MissingRemoteError", error.remote_exception)
    assert_equal(["remote.rb:1"], error.remote_backtrace)
    assert_equal(["remote.rb:1"], error.backtrace)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_remote_eof_error_is_not_converted_to_server_disconnected
    stream, writer = stream_pair
    writer.write_frame(:error, ["EOFError", "application eof", ["remote.rb:1"]])

    error = assert_raises(EOFError) { stream.result }

    assert_equal("application eof", error.message)
    assert_equal(["remote.rb:1"], error.backtrace)
    assert_same(error, stream.terminal_error)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_malformed_error_payload_becomes_terminal_remote_exception
    stream, writer = stream_pair
    writer.write_frame(:error, {
      "exception" => "ArgumentError",
      "message" => "bad input",
      "backtrace" => ["remote.rb:1"],
    })

    error = assert_raises(Urpc::RemoteException) { stream.result }

    assert_match(/invalid urpc remote error payload/, error.message)
    assert_same(error, stream.terminal_error)
    assert(stream.finished?)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_consumer_eof_error_propagates_without_finishing_stream
    stream, writer = stream_pair
    writer.write_frame(:data, "value")
    writer.write_frame(:return, "done")

    error = assert_raises(EOFError) do
      stream.each { raise(EOFError, "consumer eof") }
    end

    assert_equal("consumer eof", error.message)
    assert_equal(false, stream.finished?)
    assert_equal("done", stream.result)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_consumer_timeout_exception_propagates_without_finishing_stream
    stream, writer = stream_pair
    writer.write_frame(:data, "value")
    writer.write_frame(:return, "done")

    error = assert_raises(Urpc::TimeoutException) do
      stream.each { raise(Urpc::TimeoutException, "consumer timeout") }
    end

    assert_equal("consumer timeout", error.message)
    assert_equal(false, stream.finished?)
    assert_equal("done", stream.result)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_clean_eof_before_terminal_maps_to_server_disconnected
    stream, writer = stream_pair
    writer.write_frame(:data, "one")
    writer.close

    values = stream.each
    assert_equal("one", values.next)

    error = assert_raises(Urpc::ServerDisconnected) { values.next }
    assert_equal("urpc server disconnected before terminal response", error.message)
    assert_equal(true, stream.finished?)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_call_timeout_finishes_stream_closes_reader_and_is_retained
    stream, writer = stream_pair(timeout: 0.001)

    error = assert_raises(Urpc::TimeoutException) { stream.each.next }

    assert(stream.finished?)
    assert(stream.closed?)
    repeated_error = assert_raises(Urpc::TimeoutException) { stream.result }
    assert_same(error, repeated_error)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_partial_eof_before_terminal_maps_to_server_disconnected
    input, output = IO.pipe
    stream = Urpc::Stream.new(Urpc::FrameReader.new(input, timeout: 1))
    frame = Urpc::StreamFrame.pack(:data, "hello")
    output.write(frame.byteslice(0, 3))
    output.close

    assert_raises(Urpc::ServerDisconnected) { stream.each.next }
    assert_equal(true, stream.finished?)
  ensure
    close_io(stream)
    close_io(output)
  end

  def test_unexpected_output_frame_raises_runtime_error
    stream, writer = stream_pair
    writer.write_frame(:input_ready)

    error = assert_raises(RuntimeError) { stream.each.next }

    assert_match(/unexpected urpc output frame/, error.message)
    assert_equal(true, stream.finished?)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def test_close_closes_reader
    stream, writer = stream_pair

    stream.close

    assert(stream.closed?)
  ensure
    close_io(stream)
    close_io(writer)
  end

  def stream_pair(timeout: 1)
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout:)
    [Urpc::Stream.new(reader), Urpc::FrameWriter.new(output)]
  end
end
