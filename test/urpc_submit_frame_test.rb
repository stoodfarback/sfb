# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcSubmitFrameTest < Minitest::Test
  include(Urpc::SubmitFrame)

  def write_raw(bytes)
    File.open(Urpc.in_fifo, File::WRONLY | File::NONBLOCK) do |io|
      raise("in.fifo not writable") if !io.wait_writable(2)
      io.write_nonblock(bytes)
    end
  end

  def wait_for_exit(pid, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      done_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if done_pid
      sleep(0.05)
    end
    nil
  end

  def assert_broker_aborts(pid)
    status = wait_for_exit(pid)
    raise("broker did not exit") if !status
    refute(status.success?, "broker should have aborted with non-zero status, got #{status.inspect}")
  end

  def with_subprocess_broker
    with_root do
      pid = spawn_broker
      wait_for_broker
      begin
        yield(pid)
      ensure
        if pid
          Process.kill("TERM", pid) rescue nil
          Process.wait(pid) rescue nil
        end
      end
    end
  end

  def base_envelope(rpc_key: "k", method_name: "m", flags: 0, wait_mode_byte: WAIT_NO_SERVER, wait_ms: nil, id_bin: nil)
    id_bin ||= SecureRandom.bytes(WIRE_ID_BYTES)
    rpc_key_b = rpc_key.b
    method_b = method_name.b
    wait_bytes =
      case wait_mode_byte
      when WAIT_TIMEOUT_MS
        [WAIT_TIMEOUT_MS, wait_ms].pack("CN")
      else
        [wait_mode_byte].pack("C")
      end
    [SUBMIT_WIRE_VERSION, flags].pack("CC") +
      id_bin +
      wait_bytes +
      [rpc_key_b.bytesize].pack("C") + rpc_key_b +
      [method_b.bytesize].pack("C") + method_b
  end

  def call_for_encoding(rpc_key: "k", name: :m, bidirectional: false)
    Urpc::Call.new(
      id: SecureRandom.hex(16),
      rpc_key: rpc_key,
      name: name,
      args: [],
      kargs: {},
      cast: false,
      bidirectional: bidirectional,
    )
  end

  ## Negative tests: broker aborts on protocol violations

  def test_broker_aborts_on_bogus_wire_version
    with_subprocess_broker do |pid|
      # Version byte 99 (invalid), then enough bytes to consume the parse attempt.
      frame = [99, 0].pack("CC") + SecureRandom.bytes(WIRE_ID_BYTES) + [WAIT_NO_SERVER].pack("C") +
        [1].pack("C") + "k" + [1].pack("C") + "m"
      write_raw(frame)
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_unknown_flag_bit
    with_subprocess_broker do |pid|
      # 0x80 is not a known flag bit.
      write_raw(base_envelope(flags: 0x80))
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_bidirectional_cast
    with_subprocess_broker do |pid|
      flags = SUBMIT_FLAG_CAST | SUBMIT_FLAG_BIDIRECTIONAL
      write_raw(base_envelope(flags: flags))
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_zero_rpc_key_length
    with_subprocess_broker do |pid|
      frame = [SUBMIT_WIRE_VERSION, 0].pack("CC") +
        SecureRandom.bytes(WIRE_ID_BYTES) +
        [WAIT_NO_SERVER].pack("C") +
        [0].pack("C") + # zero-length rpc_key
        [1].pack("C") + "m"
      write_raw(frame)
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_zero_method_length
    with_subprocess_broker do |pid|
      frame = [SUBMIT_WIRE_VERSION, 0].pack("CC") +
        SecureRandom.bytes(WIRE_ID_BYTES) +
        [WAIT_NO_SERVER].pack("C") +
        [1].pack("C") + "k" +
        [0].pack("C")
      write_raw(frame)
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_invalid_utf8_rpc_key
    with_subprocess_broker do |pid|
      write_raw(base_envelope(rpc_key: "\xff".b))
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_invalid_utf8_method
    with_subprocess_broker do |pid|
      write_raw(base_envelope(method_name: "\xff".b))
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_inline_body_length_exceeds_frame_max
    with_subprocess_broker do |pid|
      envelope = base_envelope(flags: SUBMIT_FLAG_INLINE)
      # Declare a body length that would push the frame past INLINE_FRAME_MAX.
      huge_body_len = INLINE_FRAME_MAX
      frame = envelope + [huge_body_len].pack("n")
      # We only write the header part; the broker will see the bad length and abort
      # before reading the body bytes.
      write_raw(frame)
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_inline_body_length_zero
    with_subprocess_broker do |pid|
      envelope = base_envelope(flags: SUBMIT_FLAG_INLINE)
      frame = envelope + [0].pack("n")
      write_raw(frame)
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_missing_file_backed_request
    with_subprocess_broker do |pid|
      # File-backed frame (no INLINE flag) but no request file at requests/<id>.msgpack.
      id_bin = SecureRandom.bytes(WIRE_ID_BYTES)
      write_raw(base_envelope(id_bin: id_bin))
      assert_broker_aborts(pid)
    end
  end

  def test_broker_aborts_on_garbage_file_backed_request
    with_subprocess_broker do |pid|
      id_bin = SecureRandom.bytes(WIRE_ID_BYTES)
      id_hex = id_bin.unpack1("H*")
      File.write(Urpc::Call.request_path(id_hex), "not valid msgpack \xff\x00")
      write_raw(base_envelope(id_bin: id_bin))
      assert_broker_aborts(pid)
    end
  end

  def test_client_rejects_invalid_utf8_rpc_key
    client = Urpc::Client.new("unused")
    call = call_for_encoding(rpc_key: "\xff".b)
    error = assert_raises(ArgumentError) { client.build_envelope(call, inline: false) }
    assert_match(/rpc_key invalid UTF-8/, error.message)
  end

  def test_client_rejects_invalid_utf8_method
    client = Urpc::Client.new("unused")
    call = call_for_encoding(name: "\xff".b)
    error = assert_raises(ArgumentError) { client.build_envelope(call, inline: false) }
    assert_match(/method invalid UTF-8/, error.message)
  end

  def test_bidirectional_call_sets_submit_flag
    client = Urpc::Client.new("unused")
    call = call_for_encoding(bidirectional: true)
    flags = client.build_envelope(call, inline: false).unpack1("@1C")

    assert_equal(Urpc::SubmitFrame::SUBMIT_FLAG_BIDIRECTIONAL,
      flags & Urpc::SubmitFrame::SUBMIT_FLAG_BIDIRECTIONAL)
    assert_equal(0, flags & Urpc::SubmitFrame::SUBMIT_FLAG_CAST)
  end

  def test_normal_call_does_not_set_bidirectional_submit_flag
    client = Urpc::Client.new("unused")
    call = call_for_encoding
    flags = client.build_envelope(call, inline: false).unpack1("@1C")

    assert_equal(0, flags & Urpc::SubmitFrame::SUBMIT_FLAG_BIDIRECTIONAL)
  end

  ## Positive round-trip tests

  def test_inline_non_ascii_rpc_key_round_trips
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:echo) {|x| x }

      rpc_key = "café_key"
      assert(rpc_key.bytesize > rpc_key.length, "rpc_key must exercise multi-byte chars")
      start_server(rpc_key, handler)
      wait_for_backend(rpc_key)

      client = Urpc::Client.new(rpc_key, timeout: 5)
      assert_equal("world", client.call(:echo, "world"))
    end
  end

  def test_inline_max_length_rpc_key_and_method
    with_broker do
      rpc_key = "k" * 255
      method_name = ("m" * 255).to_sym

      handler = Object.new
      handler.singleton_class.define_method(method_name) {|x| x }

      start_server(rpc_key, handler)
      wait_for_backend(rpc_key)

      client = Urpc::Client.new(rpc_key, timeout: 5)
      assert_equal("hi", client.call(method_name, "hi"))
    end
  end

  def test_inline_frame_at_exact_size_boundary_round_trips
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:echo) {|x| x }

      start_server("boundary", handler)
      wait_for_backend("boundary")

      client = Urpc::Client.new("boundary", timeout: 5)
      target = Urpc::SubmitFrame::INLINE_FRAME_MAX

      # Probe with a payload in the str16 msgpack size class (256..65535 bytes) — the
      # same class the final payload will land in for INLINE_FRAME_MAX = 4076. Probing
      # with a smaller string (e.g. "") uses fixstr (1-byte header) and undercounts
      # the real frame size.
      probe_payload = "x" * 1000
      probe_call = Urpc::Call.new(
        id: SecureRandom.hex(16),
        rpc_key: "boundary",
        name: :echo,
        args: [probe_payload],
        kargs: {},
        cast: false,
      )
      probe_frame_size =
        client.build_envelope(probe_call, inline: true).bytesize + 2 +
        probe_call.body_payload.bytesize

      payload_size = probe_payload.bytesize + (target - probe_frame_size)
      raise("payload out of str16 range") if payload_size < 256 || payload_size > 65_535
      payload = "x" * payload_size

      captured = []
      client.define_singleton_method(:write_frame) do |frame|
        captured << frame
        super(frame)
      end

      assert_equal(payload, client.call(:echo, payload))
      assert_equal(1, captured.size)
      assert_equal(target, captured.first.bytesize, "frame must land exactly on INLINE_FRAME_MAX")
      flags = captured.first.unpack1("@1C")
      assert_equal(Urpc::SubmitFrame::SUBMIT_FLAG_INLINE,
        flags & Urpc::SubmitFrame::SUBMIT_FLAG_INLINE,
        "inline flag must be set")
    end
  end

  def test_call_just_above_inline_max_falls_back_to_file_backed
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:echo) {|x| x }

      start_server("overflow", handler)
      wait_for_backend("overflow")

      payload = "x" * Urpc::SubmitFrame::INLINE_FRAME_MAX

      # Confirm this exceeds the inline limit.
      probe_call = Urpc::Call.new(
        id: SecureRandom.hex(16),
        rpc_key: "overflow",
        name: :echo,
        args: [payload],
        kargs: {},
        cast: false,
      )
      probe_envelope = Urpc::Client.new("overflow").build_envelope(probe_call, inline: false)
      total = probe_envelope.bytesize + 2 + probe_call.body_payload.bytesize
      assert_operator(total, :>, Urpc::SubmitFrame::INLINE_FRAME_MAX)

      client = Urpc::Client.new("overflow", timeout: 5)
      assert_equal(payload, client.call(:echo, payload))
    end
  end

  def observing_load_body_stub(observed)
    original = Urpc::Call.method(:load_body)
    ->(id, body, **kargs) do
      observed << kargs[:wait_for_server]
      original.call(id, body, **kargs)
    end
  end

  def test_wait_for_server_zero_normalized_to_false_no_numeric_leaks
    with_broker do
      observed = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:peek) {|x| x }

      start_server("wait_zero_leak", handler)
      wait_for_backend("wait_zero_leak")

      Urpc::Call.stub(:load_body, observing_load_body_stub(observed)) do
        client = Urpc::Client.new("wait_zero_leak", timeout: 2, wait_for_server: 0)
        assert_equal("hi", client.call(:peek, "hi"))
      end

      assert_equal(false, observed.pop)
    end
  end

  def test_wait_for_server_fractional_round_trips
    with_broker do
      observed = Queue.new
      handler = Object.new
      handler.singleton_class.define_method(:peek) {|x| x }

      start_server("wait_fractional", handler)
      wait_for_backend("wait_fractional")

      Urpc::Call.stub(:load_body, observing_load_body_stub(observed)) do
        client = Urpc::Client.new("wait_fractional", timeout: 5, wait_for_server: 1.25)
        assert_equal("ok", client.call(:peek, "ok"))
      end

      assert_equal(1.25, observed.pop)
    end
  end
end
