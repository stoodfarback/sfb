# frozen_string_literal: true

require_relative("test_helper")

class UrpcSubmitFrameTest < Minitest::Test
  def test_pack_and_unpack_request_payload
    payload = Urpc::SubmitFrame.pack_request(:search, ["text"], { limit: 10 })

    request = Urpc::SubmitFrame.unpack_request(payload)

    assert_equal(:search, request.name)
    assert_equal(["text"], request.args)
    assert_equal({ limit: 10 }, request.kargs)
  end

  def test_pack_request_rejects_empty_method_name
    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_request(nil, [], {}) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_request("", [], {}) }
  end

  def test_rejects_invalid_request_payload
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_request(MessagePack.pack(["missing"])) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_request(MessagePack.pack([:symbol, [], {}])) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_request(MessagePack.pack(["", [], {}])) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_request(MessagePack.pack(["ok", {}, {}])) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_request(MessagePack.pack(["ok", [], []])) }
  end

  def test_pack_inline_frame
    id = Urpc::Id.from_hex("0123456789abcdef")
    payload = Urpc::SubmitFrame.pack_request(:echo, ["x"], {})

    frame = Urpc::SubmitFrame.pack_inline(
      id:,
      flags: Urpc::SubmitFrame::CAST,
      payload:,
    )

    header = Urpc::SubmitFrame.unpack_header(frame.byteslice(0, Urpc::SubmitFrame::HEADER_BYTES))
    assert_equal(id, header.id)
    assert_equal(payload.bytesize, header.payload_len)
    assert_equal(true, header.inline?)
    assert_equal(true, header.cast?)
    assert_equal(false, header.bidirectional?)
    assert_equal(payload, frame.byteslice(Urpc::SubmitFrame::HEADER_BYTES..))
  end

  def test_pack_file_backed_frame
    id = Urpc::Id.from_hex("0123456789abcdef")

    frame = Urpc::SubmitFrame.pack_file_backed(
      id:,
      flags: Urpc::SubmitFrame::BIDIRECTIONAL,
    )

    header = Urpc::SubmitFrame.unpack_header(frame)
    assert_equal(id, header.id)
    assert_equal(0, header.payload_len)
    assert_equal(false, header.inline?)
    assert_equal(false, header.cast?)
    assert_equal(true, header.bidirectional?)
    assert_equal(true, header.file_backed?)
  end

  def test_submission_owns_inline_request_plan
    submission = Urpc::SubmitFrame::Submission.build(:echo, ["value"], { limit: 1 }, cast: false, bidirectional: false)
    header = Urpc::SubmitFrame.unpack_header(submission.frame.byteslice(0, Urpc::SubmitFrame::HEADER_BYTES))

    assert_instance_of(Urpc::Id, submission.id)
    assert_equal(false, submission.cast?)
    assert_equal(false, submission.bidirectional?)
    assert_equal(true, submission.inline?)
    assert_equal(true, submission.output?)
    assert_equal(false, submission.input?)
    assert_nil(submission.file_payload)
    assert(header.inline?)
    assert_equal(submission.id, header.id)
    assert_equal(
      Urpc::SubmitFrame::Request.new(name: :echo, args: ["value"], kargs: { limit: 1 }),
      Urpc::SubmitFrame.unpack_request(submission.payload),
    )
  end

  def test_submission_owns_cast_and_bidirectional_artifact_plans
    cast = Urpc::SubmitFrame::Submission.build(:notify, [], {}, cast: true, bidirectional: false)
    bidirectional = Urpc::SubmitFrame::Submission.build(:chat, [], {}, cast: false, bidirectional: true)

    assert_equal(true, cast.cast?)
    assert_equal(false, cast.output?)
    assert_equal(false, cast.input?)
    assert_equal(true, Urpc::SubmitFrame.unpack_header(cast.frame.byteslice(0, Urpc::SubmitFrame::HEADER_BYTES)).cast?)

    assert_equal(true, bidirectional.bidirectional?)
    assert_equal(true, bidirectional.output?)
    assert_equal(true, bidirectional.input?)
    assert_equal(true, Urpc::SubmitFrame.unpack_header(bidirectional.frame.byteslice(0, Urpc::SubmitFrame::HEADER_BYTES)).bidirectional?)
  end

  def test_submission_owns_file_backed_request_plan
    value = "x" * (Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX + 1)
    submission = Urpc::SubmitFrame::Submission.build(:echo, [value], {}, cast: false, bidirectional: false)
    header = Urpc::SubmitFrame.unpack_header(submission.frame)

    assert_equal(false, submission.inline?)
    assert_same(submission.payload, submission.file_payload)
    assert(header.file_backed?)
    assert_equal(submission.id, header.id)
  end

  def test_rejects_unknown_flags_and_bidirectional_cast
    id = Urpc::Id.generate

    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_file_backed(id:, flags: 0x80) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_file_backed(id:, flags: Urpc::SubmitFrame::CAST | Urpc::SubmitFrame::BIDIRECTIONAL) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_header([0x80, id.bytes, 0].pack("Ca8n")) }
  end

  def test_rejects_invalid_header_size
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_header("short") }
  end

  def test_rejects_oversized_inline_payload
    id = Urpc::Id.generate
    payload = "x" * (Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX + 1)

    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_inline(id:, flags: 0, payload:) }
  end

  def test_rejects_nonzero_file_backed_payload_length
    id = Urpc::Id.generate

    assert_raises(ArgumentError) { Urpc::SubmitFrame.pack_header(id:, flags: 0, payload_len: 1) }
    assert_raises(ArgumentError) { Urpc::SubmitFrame.unpack_header([0, id.bytes, 1].pack("Ca8n")) }
  end
end
