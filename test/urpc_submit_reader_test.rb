# frozen_string_literal: true

require_relative("test_helper")

class UrpcSubmitReaderTest < Minitest::Test
  def test_reads_inline_submit
    with_reader do |reader, writer|
      id = Urpc::Id.from_hex("0123456789abcdef")
      payload = Urpc::SubmitFrame.pack_request(:echo, ["hello"], { loud: true })

      writer.write(Urpc::SubmitFrame.pack_inline(id:, flags: 0, payload:))
      submit = reader.next_submit

      assert_equal(id, submit.id)
      assert_equal(true, submit.inline?)
      assert_equal(false, submit.file_backed?)
      assert_equal(false, submit.cast?)
      assert_equal(false, submit.bidirectional?)
      assert_equal(:echo, submit.name)
      assert_equal(["hello"], submit.args)
      assert_equal({ loud: true }, submit.kargs)
      assert_equal(payload, submit.payload)
    end
  end

  def test_reads_file_backed_submit_and_unlinks_payload
    with_reader do |reader, writer, paths|
      id = Urpc::Id.from_hex("0123456789abcdef")
      payload = Urpc::SubmitFrame.pack_request(:big, ["x"], {})
      File.write(paths.call_file(id), payload)

      writer.write(Urpc::SubmitFrame.pack_file_backed(id:, flags: Urpc::SubmitFrame::CAST))
      submit = reader.next_submit

      assert_equal(false, submit.inline?)
      assert_equal(true, submit.file_backed?)
      assert_equal(true, submit.cast?)
      assert_equal(:big, submit.name)
      assert_equal(payload, submit.payload)
      assert_equal(false, File.exist?(paths.call_file(id)))
    end
  end

  def test_accepts_inline_submit_as_opaque_raw_bytes_before_hydration
    with_reader do |reader, writer, paths|
      id = Urpc::Id.from_hex("0123456789abcdef")
      payload = Urpc::SubmitFrame.pack_request(:echo, ["hello"], {})
      frame = Urpc::SubmitFrame.pack_inline(id:, flags: 0, payload:)
      writer.write(frame)

      accepted = reader.next_accepted

      assert_equal(frame, accepted.bytes)
      assert(accepted.inline?)
      submit = Urpc::SubmitReader::Accepted.new(bytes: accepted.bytes.dup.freeze).hydrate(paths)
      assert_equal(:echo, submit.name)
      assert_equal(["hello"], submit.args)
    end
  end

  def test_accepting_file_backed_submit_leaves_payload_for_hydrating_worker
    with_reader do |reader, writer, paths|
      id = Urpc::Id.from_hex("0123456789abcdef")
      payload = Urpc::SubmitFrame.pack_request(:big, ["x"], {})
      frame = Urpc::SubmitFrame.pack_file_backed(id:, flags: Urpc::SubmitFrame::CAST)
      File.write(paths.call_file(id), payload)
      writer.write(frame)

      accepted = reader.next_accepted

      assert_equal(frame, accepted.bytes)
      assert(accepted.file_backed?)
      assert(File.exist?(paths.call_file(id)))

      submit = Urpc::SubmitReader::Accepted.new(bytes: accepted.bytes.dup.freeze).hydrate(paths)
      assert_equal(:big, submit.name)
      assert_equal(payload, submit.payload)
      assert_equal(false, File.exist?(paths.call_file(id)))
    end
  end

  def test_buffers_multiple_submits_from_one_read
    with_reader do |reader, writer|
      first_id = Urpc::Id.from_hex("0123456789abcdef")
      second_id = Urpc::Id.from_hex("fedcba9876543210")
      first_payload = Urpc::SubmitFrame.pack_request(:first, [], {})
      second_payload = Urpc::SubmitFrame.pack_request(:second, [1], {})

      writer.write(
        Urpc::SubmitFrame.pack_inline(id: first_id, flags: 0, payload: first_payload) +
        Urpc::SubmitFrame.pack_inline(id: second_id, flags: Urpc::SubmitFrame::BIDIRECTIONAL, payload: second_payload)
      )

      first = reader.next_submit
      second = reader.next_submit

      assert_equal(:first, first.name)
      assert_equal(false, first.bidirectional?)
      assert_equal(:second, second.name)
      assert_equal(true, second.bidirectional?)
      assert_equal([1], second.args)
    end
  end

  def test_waits_for_partial_inline_payload
    with_reader do |reader, writer|
      id = Urpc::Id.from_hex("0123456789abcdef")
      payload = Urpc::SubmitFrame.pack_request(:later, ["value"], {})
      frame = Urpc::SubmitFrame.pack_inline(id:, flags: 0, payload:)
      thread = Thread.new do
        writer.write(frame.byteslice(0, 3))
        sleep(0.01)
        writer.write(frame.byteslice(3..))
      end

      submit = reader.next_submit

      assert_equal(:later, submit.name)
      assert_equal(["value"], submit.args)
    ensure
      thread.join if thread
    end
  end

  def test_eof_raises
    with_reader do |reader, writer|
      writer.close

      assert_raises(EOFError) { reader.next_submit }
    end
  end

  def test_close
    with_reader do |reader|
      reader.close

      assert(reader.closed?)
    end
  end

  def with_reader
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      input, output = IO.pipe
      reader = Urpc::SubmitReader.new(paths, input)
      yield(reader, output, paths)
    ensure
      close_io(reader)
      close_io(output)
    end
  end
end
