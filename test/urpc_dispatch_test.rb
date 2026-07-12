# frozen_string_literal: true

require_relative("test_helper")

class UrpcDispatchTest < Minitest::Test
  class Search < Urpc::Handler
    def call(query, limit:)
      data("searching #{query}")
      [query, limit]
    end
  end

  class ExplicitFinish < Urpc::Handler
    def call
      finish("explicit")
      "ignored"
    end
  end

  class Boom < Urpc::Handler
    def call
      raise(ArgumentError, "bad input")
    end
  end

  class UnencodableReturn < Urpc::Handler
    def call
      proc {}
    end
  end

  class RpcHandler
    def search(query, limit: 10)
      [query, limit]
    end

    def show(id:)
      "showing #{id}"
    end
  end

  def test_dispatch_round_trips_through_server
    dispatch = Urpc::Dispatch.new(search: Search)

    with_urpc_root do
      server = Urpc::Server.new("svc", &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 1)

      stream = client.stream(:search, "text", limit: 5)

      assert_equal(["searching text"], stream.to_a)
      assert_equal(["text", 5], stream.result)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def test_callable_handler_receives_rpc_arguments_and_returns_normally
    prefix = "result"
    dispatch = Urpc::Dispatch.new(
      search: ->(query, limit: 10) { [prefix, query, limit] },
    )
    req, reader = req_pair(:search, ["text"], { limit: 5 })

    assert_equal(["result", "text", 5], dispatch.call(req))
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: ["result", "text", 5]), reader.next_frame)
    assert(dispatch.endpoints.fetch(:search) < Urpc::Handler)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_proc_convertible_handler_is_normalized
    handler = Object.new
    handler.define_singleton_method(:to_proc) do
      ->(value) { "converted #{value}" }
    end
    dispatch = Urpc::Dispatch.new(convert: handler)
    req, reader = req_pair(:convert, ["value"])

    assert_equal("converted value", dispatch.call(req))
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "converted value"), reader.next_frame)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_bound_methods_from_shared_handler
    handler = RpcHandler.new
    dispatch = Urpc::Dispatch.new(
      search: handler.method(:search),
      show: handler.method(:show),
    )

    with_urpc_root do
      server = Urpc::Server.new("svc", &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 1)

      assert_equal(["text", 5], client.call(:search, "text", limit: 5))
      assert_equal("showing 12", client.call(:show, id: 12))
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end

  def test_endpoint_is_duck_typed
    endpoint = Object.new
    endpoint.define_singleton_method(:handle) do |req|
      req.finish("duck handler")
    end
    dispatch = Urpc::Dispatch.new(run: endpoint)
    req, reader = req_pair(:run)

    assert_nil(dispatch.call(req))
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "duck handler"), reader.next_frame)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_callable_handler_exception_becomes_error_response
    dispatch = Urpc::Dispatch.new(boom: -> { raise(ArgumentError, "bad callable") })
    req, reader = req_pair(:boom)

    assert_nil(dispatch.call(req))
    frame = reader.next_frame
    payload = Urpc::StreamFrame::ErrorPayload.decode(frame.value)

    assert_equal(:error, frame.type)
    assert_equal("ArgumentError", payload.exception_name)
    assert_equal("bad callable", payload.message)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_validates_handler_mapping_during_construction
    call_only = Object.new
    call_only.define_singleton_method(:call) { :ignored }

    object_error = assert_raises(ArgumentError) { Urpc::Dispatch.new(bad: Object.new) }
    call_only_error = assert_raises(ArgumentError) { Urpc::Dispatch.new(bad: call_only) }

    assert_includes(object_error.message, "dispatch endpoint must respond to #handle or #to_proc")
    assert_includes(call_only_error.message, "dispatch endpoint must respond to #handle or #to_proc")
  end

  def test_handler_does_not_overwrite_explicit_finish
    dispatch = Urpc::Dispatch.new(run: ExplicitFinish)
    req, reader = req_pair(:run)

    assert_equal("ignored", dispatch.call(req))
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "explicit"), reader.next_frame)
    assert_nil(reader.next_frame)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_handler_exception_becomes_error_response
    dispatch = Urpc::Dispatch.new(boom: Boom)
    req, reader = req_pair(:boom)

    assert_nil(dispatch.call(req))
    frame = reader.next_frame
    payload = Urpc::StreamFrame::ErrorPayload.decode(frame.value)

    assert_equal(:error, frame.type)
    assert_equal("ArgumentError", payload.exception_name)
    assert_equal("bad input", payload.message)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_terminal_serialization_failure_becomes_error_response
    dispatch = Urpc::Dispatch.new(run: UnencodableReturn)
    req, reader = req_pair(:run)

    assert_nil(dispatch.call(req))
    frame = reader.next_frame
    payload = Urpc::StreamFrame::ErrorPayload.decode(frame.value)

    assert_equal(:error, frame.type)
    assert_equal("NoMethodError", payload.exception_name)
    assert_includes(payload.message, "to_msgpack")
    assert(req.finished?)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_not_implemented_error_intentionally_escapes_dispatch
    dispatch = Urpc::Dispatch.new(run: Urpc::Handler)
    req, reader = req_pair(:run)

    error = assert_raises(NotImplementedError) { dispatch.call(req) }

    assert_equal("Urpc::Handler must implement #call", error.message)
    refute(req.finished?)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_unknown_method_becomes_error_response
    dispatch = Urpc::Dispatch.new
    req, reader = req_pair(:missing)

    assert_nil(dispatch.call(req))
    frame = reader.next_frame
    payload = Urpc::StreamFrame::ErrorPayload.decode(frame.value)

    assert_equal(:error, frame.type)
    assert_equal("ArgumentError", payload.exception_name)
    assert_equal("unknown urpc method: missing", payload.message)
  ensure
    close_req(req)
    close_io(reader)
  end

  def test_cast_exception_is_logged_and_finishes_request
    dispatch = Urpc::Dispatch.new(boom: Boom)
    req = req_without_output(:boom, cast: true)

    _stdout, stderr = capture_io do
      assert_nil(dispatch.call(req))
    end

    assert_includes(stderr, "urpc boom failed: ArgumentError: bad input")
    assert(req.finished?)
  ensure
    close_req(req)
  end

  def test_exception_after_terminal_is_logged
    handler_class = Class.new(Urpc::Handler) do
      def call
        finish("done")
        raise("late failure")
      end
    end
    dispatch = Urpc::Dispatch.new(run: handler_class)
    req, reader = req_pair(:run)

    _stdout, stderr = capture_io do
      assert_nil(dispatch.call(req))
    end

    assert_includes(stderr, "urpc run failed: RuntimeError: late failure")
    assert_equal(Urpc::StreamFrame::Frame.new(type: :return, value: "done"), reader.next_frame)
  ensure
    close_req(req)
    close_io(reader)
  end

  def req_pair(method_name, args = [], kargs = {})
    input, output = IO.pipe
    req = req_without_output(method_name, args, kargs)
    req.call.output = Urpc::FrameWriter.new(output)
    [req, Urpc::FrameReader.new(input, timeout: 1)]
  end

  def req_without_output(method_name, args = [], kargs = {}, cast: false)
    id = Urpc::Id.from_hex("0123456789abcdef")
    flags = cast ? Urpc::SubmitFrame::CAST : 0
    header = Urpc::SubmitFrame::Header.new(flags:, id:, payload_len: 0)
    request = Urpc::SubmitFrame::Request.new(name: method_name.to_sym, args:, kargs:)
    submit = Urpc::SubmitReader::Submit.new(header:, payload: "", request:)
    Urpc::Req.new(Urpc::ServerCall.new(Urpc::Paths.new("svc"), submit))
  end

  def close_req(req)
    req&.close
  end
end
