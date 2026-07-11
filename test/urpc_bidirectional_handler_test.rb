# frozen_string_literal: true

require_relative("test_helper")

class UrpcBidirectionalHandlerTest < Minitest::Test
  class Echo < Urpc::BidirectionalHandler
    def call
      data("ready")
      receive
    end
  end

  class AsyncCancel < Urpc::BidirectionalHandler
    attr_accessor(:cancelled)

    def initialize(req)
      super(req)
      self.cancelled = false
    end

    def call
      data("started")
      sleep(0.001) until cancelled
      "cancelled"
    end

    def receive_async(value)
      if value == :cancel
        self.cancelled = true
        close_input
      end
    end
  end

  class WaitForDisconnect < Urpc::BidirectionalHandler
    def call
      data("waiting")
      receive
      "received"
    rescue EOFError
      "disconnected"
    end
  end

  class NoAsyncHandler < Urpc::BidirectionalHandler
    def call
      data("waiting")
      receive
    end
  end

  class DrainThenDisconnect < Urpc::BidirectionalHandler
    def call
      data("waiting")
      value = receive
      disconnects = 2.times.map do
        receive
      rescue EOFError => e
        e.message
      end
      [value, disconnects]
    end
  end

  class ConcurrentClose < Urpc::BidirectionalHandler
    def call
      data("waiting")
      gate = Thread::Queue.new
      errors = Thread::Queue.new
      threads = 8.times.map do
        Thread.new do
          gate.pop
          close_input
        rescue => e
          errors << e
        end
      end
      threads.size.times { gate << true }
      threads.each(&:join)
      raise(errors.pop) if !errors.empty?

      receive
    rescue IOError => e
      e.message
    end
  end

  class DisconnectCallbackFailure < Urpc::BidirectionalHandler
    def call
      data("waiting")
      receive
    end

    def on_disconnect
      raise("disconnect callback failed")
    end
  end

  def test_receive_returns_synchronous_input
    with_dispatch_server(chat: Echo) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("ready", values.next)
      assert_nil(stream.send_sync("hello"))
      assert_raises(StopIteration) { values.next }
      assert_equal("hello", stream.result)
    end
  end

  def test_async_input_reaches_handler_while_call_is_busy
    with_dispatch_server(chat: AsyncCancel) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("started", values.next)
      assert_nil(stream.send_async(:cancel))
      assert_equal("cancelled", stream.result)
      assert_equal(false, stream.input_open?)
    end
  end

  def test_client_input_close_wakes_receive_with_eof
    with_dispatch_server(chat: WaitForDisconnect) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("waiting", values.next)
      assert_nil(stream.close_input)
      assert_equal("disconnected", stream.result)
    end
  end

  def test_disconnect_drains_queued_input_and_remains_observable
    with_dispatch_server(chat: DrainThenDisconnect) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("waiting", values.next)
      assert_nil(stream.send_sync("hello"))
      assert_nil(stream.close_input)
      assert_equal(["hello", ["urpc input disconnected", "urpc input disconnected"]], stream.result)
    end
  end

  def test_concurrent_close_is_idempotent_and_wakes_receive
    with_dispatch_server(chat: ConcurrentClose) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("waiting", values.next)
      assert_equal("urpc input is closed", stream.result)
    end
  end

  def test_disconnect_callback_failure_reaches_client
    with_dispatch_server(chat: DisconnectCallbackFailure) do |client|
      stream = client.bidirectional(:chat)
      values = stream.each

      assert_equal("waiting", values.next)
      assert_nil(stream.close_input)
      error = assert_raises(RuntimeError) { stream.result }
      assert_equal("disconnect callback failed", error.message)
    end
  end

  def test_default_async_callback_intentionally_raises_not_implemented
    handler = NoAsyncHandler.allocate

    error = assert_raises(NotImplementedError) { handler.receive_async(:unexpected) }

    assert_equal("UrpcBidirectionalHandlerTest::NoAsyncHandler must implement #receive_async for :unexpected", error.message)
  end

  def test_bidirectional_handler_rejects_plain_call
    with_dispatch_server(chat: Echo) do |client|
      error = assert_raises(ArgumentError) { client.call(:chat) }

      assert_equal("urpc request is not bidirectional", error.message)
    end
  end

  def with_dispatch_server(**handlers)
    with_urpc_root do
      dispatch = Urpc::Dispatch.new(**handlers)
      server = Urpc::Server.new("svc", &dispatch)
      server_thread = Thread.new { server.run }
      client = Urpc::Client.new("svc", timeout: 2)

      yield(client)
    ensure
      close_io(server)
      server_thread&.join(1)
      server_thread&.kill if server_thread&.alive?
    end
  end
end
