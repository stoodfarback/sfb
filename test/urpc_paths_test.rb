# frozen_string_literal: true

require_relative("test_helper")

class UrpcPathsTest < Minitest::Test
  def setup
    @old_root = Urpc.configured_root
    Urpc.set_root("/tmp/urpc2_test")
  end

  def teardown
    Urpc.configured_root = @old_root
  end

  def test_paths_for_service_key
    paths = Urpc::Paths.new("agent_mail_v1")
    id = Urpc::Id.from_hex("0123456789abcdef")

    assert_equal("/tmp/urpc2_test/agent_mail_v1", paths.dir)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/server.lock", paths.server_lock)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/submit.fifo", paths.submit_fifo)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/calls", paths.calls_dir)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/output", paths.output_dir)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/input", paths.input_dir)
    assert_equal("/tmp/urpc2_test/agent_mail_v1/calls/0123456789abcdef.msgpack", paths.call_file(id))
    assert_equal("/tmp/urpc2_test/agent_mail_v1/output/0123456789abcdef.fifo", paths.output_fifo(id))
    assert_equal("/tmp/urpc2_test/agent_mail_v1/input/0123456789abcdef.fifo", paths.input_fifo(id))
  end

  def test_rejects_invalid_service_keys
    [nil, "", "Agent", "agent-mail", "agent.mail", "agent/mail", "agent mail", "é"].each do |key|
      assert_raises(ArgumentError) { Urpc::Paths.new(key) }
    end
  end

  def test_id_round_trips
    id = Urpc::Id.from_hex("0123456789abcdef")

    assert_equal("0123456789abcdef", id.hex)
    assert_equal(id, Urpc::Id.from_bytes(id.bytes))
    assert_equal(id, Urpc::Id.from_hex(id.hex))
  end

  def test_id_generation_uses_eight_random_bytes
    id = Urpc::Id.generate

    assert_equal(8, id.bytes.bytesize)
    assert_match(/\A[0-9a-f]{16}\z/, id.hex)
  end

  def test_rejects_invalid_ids
    ["", "1234", "0123456789abcdeg", "0123456789ABCDEF", nil].each do |hex|
      assert_raises(ArgumentError) { Urpc::Id.from_hex(hex) }
    end

    assert_raises(ArgumentError) { Urpc::Id.from_bytes("short") }
  end
end
