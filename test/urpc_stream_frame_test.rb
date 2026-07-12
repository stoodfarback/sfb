# frozen_string_literal: true

require_relative("test_helper")

class UrpcStreamFrameTest < Minitest::Test
  def test_pack_payload_frames
    assert_equal([Urpc::StreamFrame::DATA].pack("C") + MessagePack.pack("value"), Urpc::StreamFrame.pack(:data, "value"))
    assert_equal([Urpc::StreamFrame::RETURN].pack("C") + MessagePack.pack(nil), Urpc::StreamFrame.pack(:return, nil))
    assert_equal([Urpc::StreamFrame::ERROR].pack("C") + MessagePack.pack(["RuntimeError", "bad", []]), Urpc::StreamFrame.pack(:error, ["RuntimeError", "bad", []]))
    assert_equal([Urpc::StreamFrame::SYNC].pack("C") + MessagePack.pack(123), Urpc::StreamFrame.pack(:sync, 123))
    assert_equal([Urpc::StreamFrame::ASYNC].pack("C") + MessagePack.pack(:cancel), Urpc::StreamFrame.pack(:async, :cancel))
  end

  def test_error_payload_codec
    error = ArgumentError.new("bad input")
    error.set_backtrace(["handler.rb:1"])
    encoded = Urpc::StreamFrame::ErrorPayload.encode(error)

    assert_equal(["ArgumentError", "bad input", ["handler.rb:1"]], encoded)
    assert_equal(
      Urpc::StreamFrame::ErrorPayload.new(exception_name: "ArgumentError", message: "bad input", backtrace: ["handler.rb:1"]),
      Urpc::StreamFrame::ErrorPayload.decode(encoded),
    )
  end

  def test_error_payload_codec_normalizes_missing_backtrace
    assert_equal(["RuntimeError", "bad", []], Urpc::StreamFrame::ErrorPayload.encode(RuntimeError.new("bad")))
  end

  def test_error_payload_codec_rejects_malformed_values
    invalid = [
      { exception: "RuntimeError", message: "bad", backtrace: [] },
      ["RuntimeError", "bad"],
      ["", "bad", []],
      ["RuntimeError", nil, []],
      ["RuntimeError", "bad", nil],
      ["RuntimeError", "bad", [1]],
    ]

    invalid.each do |value|
      error = assert_raises(ArgumentError) { Urpc::StreamFrame::ErrorPayload.decode(value) }
      assert_match(/invalid urpc remote error payload/, error.message)
    end
  end

  def test_pack_no_payload_frames
    assert_equal([Urpc::StreamFrame::INPUT_READY].pack("C"), Urpc::StreamFrame.pack(:input_ready))
    assert_equal([Urpc::StreamFrame::READY].pack("C"), Urpc::StreamFrame.pack(:ready))
  end

  def test_rejects_invalid_pack_calls
    assert_raises(ArgumentError) { Urpc::StreamFrame.pack(:bogus) }
    assert_raises(ArgumentError) { Urpc::StreamFrame.pack(:data) }
    assert_raises(ArgumentError) { Urpc::StreamFrame.pack(:ready, nil) }
  end

  def test_parser_buffers_partial_payload_frames
    parser = Urpc::StreamFrame::Parser.new
    data = Urpc::StreamFrame.pack(:data, "hello")
    return_frame = Urpc::StreamFrame.pack(:return, "done")

    parser.feed(data.byteslice(0, 2))
    assert_equal([], parser.each_frame.to_a)

    parser.feed(data.byteslice(2..))
    parser.feed(Urpc::StreamFrame.pack(:input_ready))
    parser.feed(return_frame)

    frames = parser.each_frame.to_a
    assert_equal([
      Urpc::StreamFrame::Frame.new(type: :data, value: "hello"),
      Urpc::StreamFrame::Frame.new(type: :input_ready, value: nil),
      Urpc::StreamFrame::Frame.new(type: :return, value: "done"),
    ], frames)
  end

  def test_parser_handles_multiple_frames_in_one_feed
    parser = Urpc::StreamFrame::Parser.new
    bytes = Urpc::StreamFrame.pack(:ready) +
      Urpc::StreamFrame.pack(:sync, "answer") +
      Urpc::StreamFrame.pack(:async, nil)

    parser.feed(bytes)

    assert_equal([
      Urpc::StreamFrame::Frame.new(type: :ready, value: nil),
      Urpc::StreamFrame::Frame.new(type: :sync, value: "answer"),
      Urpc::StreamFrame::Frame.new(type: :async, value: nil),
    ], parser.each_frame.to_a)
  end

  def test_parser_incrementally_reads_large_payload_one_byte_at_a_time
    parser = Urpc::StreamFrame::Parser.new
    payload = "x" * (256 * 1024)
    bytes = Urpc::StreamFrame.pack(:data, payload) + Urpc::StreamFrame.pack(:return, "done")
    frames = []

    bytes.each_byte do |byte|
      parser.feed(byte.chr(Encoding::BINARY))
      frame = parser.read_frame
      if frame
        frames << frame
      end
    end

    assert_equal([
      Urpc::StreamFrame::Frame.new(type: :data, value: payload),
      Urpc::StreamFrame::Frame.new(type: :return, value: "done"),
    ], frames)
  end

  def test_parser_incrementally_reads_large_compound_payload
    parser = Urpc::StreamFrame::Parser.new
    payload = Array.new(2_000) { { time: it, weight: it / 10.0 } }
    bytes = Urpc::StreamFrame.pack(:return, payload)

    bytes.each_byte.each_slice(16 * 1024) do |chunk|
      parser.feed(chunk.pack("C*"))
    end

    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: payload), parser.read_frame)
  end

  def test_parser_reports_partial_payload_after_unpacker_consumes_buffer
    parser = Urpc::StreamFrame::Parser.new
    frame = Urpc::StreamFrame.pack(:data, "hello")
    parser.feed(frame.byteslice(0, 3))

    assert_nil(parser.read_frame)
    assert_equal("", parser.buffer)
    assert(parser.partial?)
  end

  def test_parser_rejects_unknown_tag
    parser = Urpc::StreamFrame::Parser.new
    parser.feed([0xff].pack("C"))

    error = assert_raises(ArgumentError) { parser.each_frame.to_a }
    assert_includes(error.message, "unknown stream frame tag")
  end

  def test_parser_raises_for_malformed_msgpack_payload
    parser = Urpc::StreamFrame::Parser.new
    parser.feed([Urpc::StreamFrame::DATA, 0xc1].pack("CC"))

    assert_raises(MessagePack::MalformedFormatError) { parser.each_frame.to_a }
  end
end
