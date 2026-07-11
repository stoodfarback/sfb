# frozen_string_literal: true

require_relative("test_helper")

class UrpcRequestRunnerTest < Minitest::Test
  def test_client_disconnect_does_not_escape
    req = build_req
    handler = proc do
      req.close
      raise(Urpc::ClientDisconnected, "client went away")
    end

    assert_nil(Urpc::RequestRunner.call(handler, req))
    assert(req.finished?)
    assert(req.call.closed?)
  ensure
    req&.close
  end

  def test_application_epipe_escapes
    req = build_req
    handler = proc { raise(Errno::EPIPE, "application pipe failed") }

    assert_raises(Errno::EPIPE) { Urpc::RequestRunner.call(handler, req) }
    refute(req.finished?)
  ensure
    req&.close
  end

  def build_req
    id = Urpc::Id.from_hex("0123456789abcdef")
    header = Urpc::SubmitFrame::Header.new(flags: Urpc::SubmitFrame::CAST, id:, payload_len: 0)
    request = Urpc::SubmitFrame::Request.new(name: :test, args: [], kargs: {})
    submit = Urpc::SubmitReader::Submit.new(header:, payload: "", request:)
    Urpc::Req.new(Urpc::ServerCall.new(Urpc::Paths.new("svc"), submit))
  end
end
