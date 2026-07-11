# frozen_string_literal: true

require_relative("test_helper")

class UrpcBidirectionalTest < Minitest::Test
  def test_await_input_consumes_input_ready_and_writes_ready
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)

      input = client.await_input

      assert_equal(true, input.open?)
      assert_equal(false, File.exist?(server.paths.input_fifo(server.id)))
      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), server.input.next_frame)
      assert_equal(true, client.input_open?)
    end
  end

  def test_send_sync_and_async_await_input_automatically
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)

      assert_nil(client.send_sync("question"))
      assert_nil(client.send_async({ cancel: true }))

      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), server.input.next_frame)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: "question"), server.input.next_frame)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :async, value: { cancel: true }), server.input.next_frame)
    end
  end

  def test_concurrent_initial_sends_share_one_input_attachment
    with_bidirectional_pair do |client, server|
      start = Thread::Queue.new
      send_threads = [
        Thread.new do
          start.pop
          client.send_sync(:one)
        end,
        Thread.new do
          start.pop
          client.send_async(:two)
        end,
      ]
      send_threads.size.times { start << true }
      wait_for_threads_to_sleep(*send_threads)

      server.output.write_frame(:input_ready)
      server.output.write_frame(:data, "wake any duplicate prologue reader")

      send_threads.each { assert_nil(it.value) }
      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), server.input.next_frame)
      input_frames = 2.times.map { server.input.next_frame }
      assert_equal(
        [[:async, :two], [:sync, :one]],
        input_frames.map { [it.type, it.value] }.sort_by(&:first),
      )
    ensure
      send_threads&.each do |thread|
        thread.join(1)
        thread.kill if thread.alive?
      end
    end
  end

  def test_close_input_waits_for_in_progress_frame
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)
      client.await_input
      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), server.input.next_frame)

      payload = "x" * (256 * 1024)
      send_thread = Thread.new { client.send_sync(payload) }
      wait_for_threads_to_sleep(send_thread)
      close_thread = Thread.new { client.close_input }
      wait_for_threads_to_sleep(close_thread)

      assert(close_thread.alive?)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :sync, value: payload), server.input.next_frame)
      assert_nil(send_thread.value)
      assert_nil(close_thread.value)
      assert_nil(server.input.next_frame)
    ensure
      send_thread&.join(1)
      send_thread&.kill if send_thread&.alive?
      close_thread&.join(1)
      close_thread&.kill if close_thread&.alive?
    end
  end

  def test_each_consumes_prologue_then_reads_output_data
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)
      server.output.write_frame(:data, "one")
      server.output.write_frame(:return, "done")

      values = client.each
      assert_equal("one", values.next)
      assert_raises(StopIteration) { values.next }
      assert_equal(true, client.finished?)
      assert_equal(false, client.input_open?)
      assert_equal("done", client.result)
    end
  end

  def test_result_consumes_prologue_and_returns_terminal_value
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)
      server.output.write_frame(:data, "ignored")
      server.output.write_frame(:return, 123)

      assert_equal(123, client.result)
      assert_equal(true, client.finished?)
      assert_equal(false, client.input_open?)
    end
  end

  def test_close_input_before_user_events_sends_ready_then_half_closes
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)

      assert_nil(client.close_input)

      assert_equal(false, client.input_open?)
      assert_equal(Urpc::StreamFrame::Frame.new(type: :ready, value: nil), server.input.next_frame)
      assert_nil(server.input.next_frame)
      assert_raises(IOError) { client.send_sync("late") }
    end
  end

  def test_unexpected_prologue_raises
    input, output = IO.pipe
    writer = Urpc::FrameWriter.new(output)
    reader = Urpc::FrameReader.new(input, timeout: 1)
    paths = Urpc::Paths.new("svc")
    client = Urpc::Bidirectional.new(reader, paths:, id: Urpc::Id.from_hex("0123456789abcdef"))
    writer.write_frame(:data, "too soon")

    error = assert_raises(RuntimeError) { client.await_input }

    assert_match(/expected INPUT_READY/, error.message)
  ensure
    close_io(client)
    close_io(writer)
  end

  def test_eof_before_input_ready_maps_to_server_disconnected
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 1)
    paths = Urpc::Paths.new("svc")
    client = Urpc::Bidirectional.new(reader, paths:, id: Urpc::Id.from_hex("0123456789abcdef"))
    output.close

    error = assert_raises(Urpc::ServerDisconnected) { client.await_input }
    assert(client.finished?)
    assert(client.closed?)
    assert_equal(false, client.input_open?)
    repeated_error = assert_raises(Urpc::ServerDisconnected) { client.result }
    assert_same(error, repeated_error)
  ensure
    close_io(client)
    close_io(output)
  end

  def test_timeout_before_input_ready_finishes_bidirectional
    input, output = IO.pipe
    reader = Urpc::FrameReader.new(input, timeout: 0.001)
    paths = Urpc::Paths.new("svc")
    client = Urpc::Bidirectional.new(reader, paths:, id: Urpc::Id.from_hex("0123456789abcdef"))

    assert_raises(Urpc::TimeoutException) { client.await_input }
    assert(client.finished?)
    assert(client.closed?)
    assert_equal(false, client.input_open?)
  ensure
    close_io(client)
    close_io(output)
  end

  def test_close_closes_input_and_output
    with_bidirectional_pair do |client, server|
      server.output.write_frame(:input_ready)
      client.await_input

      client.close

      assert_equal(false, client.input_open?)
      assert_equal(true, client.closed?)
    end
  end

  ServerSide = Data.define(:paths, :id, :artifacts, :output, :input)

  def wait_for_threads_to_sleep(*threads)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      return if threads.all? { it.status == "sleep" }
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise("threads did not block in time")
      end
      Thread.pass
    end
  end

  def with_bidirectional_pair
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = Urpc::SubmitFrame::Submission.build(:chat, [], {}, cast: false, bidirectional: true)
      id = submission.id
      artifacts = Urpc::CallArtifacts.prepare(paths, submission)
      output_io = File.open(paths.output_fifo(id), File::WRONLY | File::NONBLOCK)
      input_io = File.open(paths.input_fifo(id), File::RDONLY | File::NONBLOCK)

      client_reader = Urpc::FrameReader.new(artifacts.output_io, timeout: 1)
      client = Urpc::Bidirectional.new(client_reader, paths:, id:)
      server = ServerSide.new(
        paths:,
        id:,
        artifacts:,
        output: Urpc::FrameWriter.new(output_io),
        input: Urpc::FrameReader.new(input_io, timeout: 1),
      )

      yield(client, server)
    ensure
      close_io(client)
      close_io(server&.output)
      close_io(server&.input)
      close_io(server&.artifacts)
    end
  end
end
