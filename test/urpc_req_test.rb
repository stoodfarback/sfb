# frozen_string_literal: true

require_relative("test_helper")

class UrpcReqTest < Minitest::Test
  def test_metadata
    req, _reader = req_pair(:search, ["text"], { limit: 5 })

    assert_equal(:search, req.name)
    assert_equal(["text"], req.args)
    assert_equal({ limit: 5 }, req.kargs)
    assert_equal(false, req.cast?)
    assert_equal(false, req.bidirectional?)
    assert_equal(false, req.finished?)
  ensure
    close_io(req)
    close_io(_reader)
  end

  def test_data_and_finish_write_frames_and_close_request
    req, reader = req_pair(:watch)

    assert_nil(req.data("one"))
    assert_nil(req.finish("done"))

    assert_equal(Urpc::StreamFrame::Frame.new(type: :data, value: "one"), reader.next_frame)
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "done"), reader.next_frame)
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_error_writes_terminal_error_and_closes_request
    req, reader = req_pair(:boom)
    error = ArgumentError.new("bad input")
    error.set_backtrace(["handler.rb:1"])

    assert_nil(req.error(error))
    frame = reader.next_frame

    assert_equal(:error, frame.type)
    assert_equal(["ArgumentError", "bad input", ["handler.rb:1"]], frame.value)
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_terminal_serialization_failure_leaves_request_open_for_an_error_response
    req, reader = req_pair(:echo)

    error = assert_raises(NoMethodError) { req.finish(proc {}) }

    refute(req.finished?)
    refute(req.call.closed?)
    assert_nil(req.error(error))

    frame = reader.next_frame
    assert_equal(:error, frame.type)
    payload = Urpc::StreamFrame::ErrorPayload.decode(frame.value)
    assert_equal("NoMethodError", payload.exception_name)
    assert_includes(payload.message, "to_msgpack")
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_data_epipe_becomes_client_disconnected_and_closes_request
    req, reader = req_pair(:watch)
    reader.close

    error = assert_raises(Urpc::ClientDisconnected) { req.data("late") }

    assert_kind_of(Errno::EPIPE, error.cause)
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_terminal_epipe_becomes_client_disconnected_and_closes_request
    req, reader = req_pair(:watch)
    reader.close

    error = assert_raises(Urpc::ClientDisconnected) { req.finish("late") }

    assert_kind_of(Errno::EPIPE, error.cause)
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_cast_uses_normal_lifecycle_without_writing_responses
    req = req_without_output(:log, cast: true)

    assert_equal(false, req.finished?)
    assert_nil(req.data("ignored"))
    assert_equal(false, req.finished?)
    assert_nil(req.finish("ignored"))
    assert(req.finished?)
    assert_raises(IOError) { req.data("late") }
  ensure
    close_io(req)
  end

  def test_cast_error_finishes_without_writing_error
    req = req_without_output(:log, cast: true)

    assert_nil(req.error(RuntimeError.new("cast failed")))
    assert(req.finished?)
  ensure
    close_io(req)
  end

  def test_response_after_terminal_raises
    req, reader = req_pair(:echo)
    req.finish("done")

    assert_raises(IOError) { req.data("late") }
    assert_raises(IOError) { req.finish("late") }
    assert_raises(IOError) { req.error(RuntimeError.new("late")) }
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_conditional_terminal_response_has_one_winner
    req, reader = req_pair(:race)
    start = Thread::Queue.new
    terminal_threads = [
      Thread.new do
        start.pop
        req.finish_if_open("finished")
      end,
      Thread.new do
        start.pop
        req.error_if_open(RuntimeError.new("failed"))
      end,
    ]
    terminal_threads.size.times { start << true }

    results = terminal_threads.map(&:value)
    frame = reader.next_frame

    assert_equal(1, results.count(true))
    assert_equal(1, results.count(false))
    assert_includes([:return, :error], frame.type)
    assert_nil(reader.next_frame)
  ensure
    terminal_threads&.each do |thread|
      thread.join(1)
      thread.kill if thread.alive?
    end
    close_io(req)
    close_io(reader)
  end

  def test_conditional_terminal_serialization_failure_leaves_request_open
    req, reader = req_pair(:echo)

    assert_raises(NoMethodError) { req.finish_if_open(proc {}) }

    assert_equal(false, req.finished?)
    assert_equal(true, req.error_if_open(RuntimeError.new("serialization failed")))
    assert_equal(:error, reader.next_frame.type)
  ensure
    close_io(req)
    close_io(reader)
  end

  def test_next_input_returns_tagged_frames_and_raises_on_disconnect
    req = req_without_output(:chat, bidirectional: true)
    input_reader, input_writer = IO.pipe
    req.call.input_reader = Urpc::FrameReader.new(input_reader, timeout: 1)
    writer = Urpc::FrameWriter.new(input_writer)
    writer.write_frame(:sync, "question")
    writer.write_frame(:async, { cancel: true })

    assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: "question"), req.next_input)
    assert_equal(Urpc::StreamFrame::Frame.new(type: :async, value: { cancel: true }), req.next_input)

    writer.close
    assert_raises(EOFError) { req.next_input }
  ensure
    close_io(req)
    close_io(writer)
  end

  def test_next_input_rejects_non_bidirectional_request
    req, reader = req_pair(:echo)

    assert_raises(IOError) { req.next_input }
  ensure
    close_io(req)
    close_io(reader)
  end

  def close_io(object)
    return if !object

    if object.is_a?(Urpc::Req)
      object.close
    else
      super
    end
  end

  def req_pair(method_name, args = [], kargs = {})
    input, output = IO.pipe
    req = req_without_output(method_name, args, kargs)
    req.call.output = Urpc::FrameWriter.new(output)
    [req, Urpc::FrameReader.new(input, timeout: 1)]
  end

  def req_without_output(method_name, args = [], kargs = {}, cast: false, bidirectional: false)
    id = Urpc::Id.from_hex("0123456789abcdef")
    flags = 0
    flags |= Urpc::SubmitFrame::CAST if cast
    flags |= Urpc::SubmitFrame::BIDIRECTIONAL if bidirectional
    header = Urpc::SubmitFrame::Header.new(flags:, id:, payload_len: 0)
    request = Urpc::SubmitFrame::Request.new(name: method_name.to_sym, args:, kargs:)
    submit = Urpc::SubmitReader::Submit.new(header:, payload: "", request:)
    Urpc::Req.new(Urpc::ServerCall.new(Urpc::Paths.new("svc"), submit))
  end
end
