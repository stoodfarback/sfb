# frozen_string_literal: true

require_relative("urpc_test_helper")
require("timeout")

class UrpcMonitorTest < Minitest::Test
  def test_monitor_receives_rpc_calls
    with_broker do
      handler = Object.new
      handler.define_singleton_method(:hello) {|left, right| left + right }
      start_server("monitor_test", handler)
      wait_for_backend("monitor_test", count: 1)

      sock = UNIXSocket.new(Urpc.monitor_sock)

      result = Urpc::Client.new("monitor_test", timeout: 5).call(:hello, 1, 2)
      assert_equal(3, result)

      line = Timeout.timeout(2) do
        line = sock.gets
      rescue Timeout::Error
        flunk("Monitor did not receive any data within 2 seconds")
      end

      assert_match(/\A\[.*\] \[.{8}\] CALL monitor_test #hello\(1, 2\)\n\z/, line)

      line = Timeout.timeout(2) do
        line = sock.gets
      rescue Timeout::Error
        flunk("Monitor did not receive a response within 2 seconds")
      end

      assert_match(/\A\[.*\] \{.{8}\} RET 3\n\z/, line)

      sock.close rescue nil
    end
  end

  def test_monitor_receives_streaming_data_and_error_responses
    with_broker do
      handler = Object.new
      handler.define_singleton_method(:hello) do |req|
        req.stream.data("chunk")
        req.stream.error(RuntimeError.new("boom"))
      end
      start_stream_server("monitor_stream_test", handler)
      wait_for_backend("monitor_stream_test", count: 1)

      sock = UNIXSocket.new(Urpc.monitor_sock)

      stream = Urpc::Client.new("monitor_stream_test", timeout: 5).stream(:hello)
      assert_equal("chunk", stream.next_event.data)
      assert_raises(RuntimeError) { stream.result }

      lines = Timeout.timeout(2) { 3.times.map { sock.gets } }

      assert_match(/\A\[.*\] \[.{8}\] CALL monitor_stream_test #hello\(\)\n\z/, lines[0])
      assert_match(/\A\[.*\] \{.{8}\} DAT "chunk"\n\z/, lines[1])
      assert_match(/\A\[.*\] \{.{8}\} ERR \{exception: "RuntimeError", message: "boom"/, lines[2])

      sock.close rescue nil
    end
  end

  def test_monitor_response_preview_is_limited_to_eighty_chars
    with_broker do
      payload = "x" * 100
      handler = Object.new
      handler.define_singleton_method(:hello) { payload }
      start_server("monitor_preview_test", handler)
      wait_for_backend("monitor_preview_test", count: 1)

      sock = UNIXSocket.new(Urpc.monitor_sock)

      result = Urpc::Client.new("monitor_preview_test", timeout: 5).call(:hello)
      assert_equal(payload, result)

      _call_line = Timeout.timeout(2) { sock.gets }
      response_line = Timeout.timeout(2) { sock.gets }

      preview = response_line.split("} RET ", 2).fetch(1).chomp
      assert_equal(payload.inspect[0, 80], preview)

      sock.close rescue nil
    end
  end
end
