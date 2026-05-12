# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcBidirectionalTest < Minitest::Test
  def bidirectional_handler(handler_class)
    Object.new.tap do |handler|
      handler.define_singleton_method(:call) do |req|
        req.handle_bidirectional!(handler_class)
      end
    end
  end

  def test_handle_with_runs_call_handler_and_auto_finishes
    with_broker do
      handler_class = Class.new(Urpc::CallHandler) do
        def run!
          data("started")
          "done"
        end
      end

      handler = Object.new
      handler.define_singleton_method(:call) do |req|
        req.handle_with!(handler_class)
      end

      start_stream_server("call_handler", handler)
      wait_for_backend("call_handler")

      stream = Urpc::Client.new("call_handler", timeout: 5).stream(:call)
      events = []
      stream.each_event { events << [it.type, it.data] }

      assert_equal([[:data, "started"], [:return, "done"]], events)
    end
  end

  def test_handle_bidirectional_rejects_non_bidirectional_handler
    with_broker do
      handler_class = Class.new(Urpc::CallHandler) do
        def run! = "done"
      end

      handler = Object.new
      handler.define_singleton_method(:call) do |req|
        req.handle_bidirectional!(handler_class)
      end

      start_stream_server("bad_bidirectional", handler)
      wait_for_backend("bad_bidirectional")

      e = assert_raises(ArgumentError) do
        Urpc::Client.new("bad_bidirectional", timeout: 5).call(:call)
      end
      assert_match(/must be a Urpc::BidirectionalHandler/, e.message)
    end
  end

  def test_await_inbox_opens_before_application_data
    with_broker do
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        def run!
          data("after-open")
          finish("done")
        end
      end

      start_stream_server("await_inbox", bidirectional_handler(handler_class))
      wait_for_backend("await_inbox")

      stream = Urpc::Client.new("await_inbox", timeout: 5).stream(:call)
      assert(stream.await_inbox)
      assert(stream.inbox_open?)
      event = stream.next_event
      assert_equal([:data, "after-open"], [event.type, event.data])
      assert_equal("done", stream.result)
    end
  end

  def test_sync_prompt_round_trip
    with_broker do
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        def run!
          data(prompt: "Apply changes?")
          answer = receive
          finish(answer == "y" ? "applied" : "aborted")
        end
      end

      start_stream_server("sync_prompt", bidirectional_handler(handler_class))
      wait_for_backend("sync_prompt")

      stream = Urpc::Client.new("sync_prompt", timeout: 5).stream(:call)
      event = stream.next_event
      assert_equal(:data, event.type)
      assert_equal({ prompt: "Apply changes?" }, event.data)

      stream.send_sync("y")
      assert_equal("applied", stream.result)
    end
  end

  def test_async_cancel_stops_long_running_work
    with_broker do
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        attr_accessor(:cancel_requested)

        def receive_async(value)
          self.cancel_requested = true if value == :cancel
        end

        def run!
          data("started")
          100.times do
            break if cancel_requested
            sleep(0.01)
          end
          finish(cancel_requested ? "cancelled" : "completed")
        end
      end

      start_stream_server("async_cancel", bidirectional_handler(handler_class))
      wait_for_backend("async_cancel")

      stream = Urpc::Client.new("async_cancel", timeout: 5).stream(:call)
      assert_equal("started", stream.next_event.data)
      stream.send_async(:cancel)

      assert_equal("cancelled", stream.result)
    end
  end

  def test_close_inbox_disconnects_server_receive
    with_broker do
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        def run!
          data("waiting")
          receive
          finish("received")
        rescue EOFError
          finish("disconnected")
        end
      end

      start_stream_server("disconnect_receive", bidirectional_handler(handler_class))
      wait_for_backend("disconnect_receive")

      stream = Urpc::Client.new("disconnect_receive", timeout: 5).stream(:call)
      assert_equal("waiting", stream.next_event.data)
      stream.close_inbox

      assert_equal("disconnected", stream.result)
    end
  end

  def test_inbox_fifo_is_unlinked_after_success
    with_broker do
      paths = Queue.new
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        attr_accessor(:paths)

        def initialize(req, paths:)
          super(req)
          self.paths = paths
        end

        def setup_inbox!
          super
          paths << inbox.path
        end

        def run!
          finish("done")
        end
      end

      handler = Object.new
      handler.define_singleton_method(:call) do |req|
        req.handle_bidirectional!(handler_class, paths:)
      end

      start_stream_server("cleanup_inbox", handler)
      wait_for_backend("cleanup_inbox")

      stream = Urpc::Client.new("cleanup_inbox", timeout: 5).stream(:call)
      assert(stream.await_inbox)
      path = paths.pop
      assert_equal("done", stream.result)
      assert(poll_until { !File.exist?(path) }, "inbox FIFO was not unlinked: #{path}")
    end
  end

  def test_inbox_fifo_is_unlinked_after_error
    with_broker do
      paths = Queue.new
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        attr_accessor(:paths)

        def initialize(req, paths:)
          super(req)
          self.paths = paths
        end

        def setup_inbox!
          super
          paths << inbox.path
        end

        def run!
          raise("boom")
        end
      end

      handler = Object.new
      handler.define_singleton_method(:call) do |req|
        req.handle_bidirectional!(handler_class, paths:)
      end

      start_stream_server("cleanup_error_inbox", handler)
      wait_for_backend("cleanup_error_inbox")

      stream = Urpc::Client.new("cleanup_error_inbox", timeout: 5).stream(:call)
      assert(stream.await_inbox)
      path = paths.pop
      e = assert_raises(RuntimeError) { stream.result }
      assert_equal("boom", e.message)
      assert(poll_until { !File.exist?(path) }, "inbox FIFO was not unlinked: #{path}")
    end
  end

  def test_inbox_fifo_is_unlinked_after_client_disconnect
    with_broker do
      paths = Queue.new
      handler_class = Class.new(Urpc::BidirectionalHandler) do
        attr_accessor(:paths)

        def initialize(req, paths:)
          super(req)
          self.paths = paths
        end

        def setup_inbox!
          super
          paths << inbox.path
        end

        def run!
          receive
          finish("received")
        rescue EOFError
          finish("disconnected")
        end
      end

      handler = Object.new
      handler.define_singleton_method(:call) do |req|
        req.handle_bidirectional!(handler_class, paths:)
      end

      start_stream_server("cleanup_disconnect_inbox", handler)
      wait_for_backend("cleanup_disconnect_inbox")

      stream = Urpc::Client.new("cleanup_disconnect_inbox", timeout: 5).stream(:call)
      assert(stream.await_inbox)
      path = paths.pop
      stream.close_inbox

      assert_equal("disconnected", stream.result)
      assert(poll_until { !File.exist?(path) }, "inbox FIFO was not unlinked: #{path}")
    end
  end

  def test_bidirectional_stream_multiplexes_with_normal_stream
    with_broker do
      bidirectional_class = Class.new(Urpc::BidirectionalHandler) do
        def run!
          data([:bidir, :ready])
          answer = receive
          finish([:bidir, answer])
        end
      end

      bidirectional = bidirectional_handler(bidirectional_class)
      normal = Class.new do
        def call(req)
          req.stream.data([:normal, :a])
          req.stream.data([:normal, :b])
          req.stream.return([:normal, :done])
        end
      end.new

      start_stream_server("mixed_bidir", bidirectional)
      start_stream_server("mixed_normal", normal)
      wait_for_backend("mixed_bidir")
      wait_for_backend("mixed_normal")

      bidirectional_client = Urpc::Client.new("mixed_bidir", timeout: 5)
      normal_client = Urpc::Client.new("mixed_normal", timeout: 5)
      bidirectional_stream = bidirectional_client.stream(:call)
      normal_stream = normal_client.stream(:call)
      events = []

      bidirectional_client.each_event(bidirectional_stream, normal_stream) do |stream, event|
        source = stream.equal?(bidirectional_stream) ? :bidir : :normal
        events << [source, event.type, event.data]
        bidirectional_stream.send_sync("ok") if source == :bidir && event.type == :data
      end

      bidirectional_events = events.select { it[0] == :bidir }
      normal_events = events.select { it[0] == :normal }

      assert_equal([
        [:bidir, :data, [:bidir, :ready]],
        [:bidir, :return, [:bidir, "ok"]],
      ], bidirectional_events)
      assert_equal([
        [:normal, :data, [:normal, :a]],
        [:normal, :data, [:normal, :b]],
        [:normal, :return, [:normal, :done]],
      ], normal_events)
    end
  end
end
