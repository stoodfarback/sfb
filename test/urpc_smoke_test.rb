# frozen_string_literal: true

require_relative("urpc_test_helper")

class UrpcSmokeTest < Minitest::Test
  def echo_handler
    Class.new do
      def echo(x) = x
      def add(a, b) = a + b
      def kw(name:, age:) = "#{name}=#{age}"
      def boom = raise(ArgumentError, "kaboom")
    end.new
  end

  def test_call_rejects_block
    with_broker do
      client = Urpc::Client.new("echo")
      assert_raises(ArgumentError, "block not allowed over RPC") do
        client.call(:echo) {}
      end
    end
  end

  def test_call_returns_false
    with_broker do
      handler = Object.new
      handler.singleton_class.define_method(:ret_false) { false }
      start_server("f", handler)
      wait_for_backend("f")
      client = Urpc::Client.new("f", timeout: 5)
      assert_equal(false, client.call(:ret_false))
    end
  end

  def test_basic_call_returns_value
    with_broker do
      start_server("echo", echo_handler)
      wait_for_backend("echo")

      client = Urpc::Client.new("echo", timeout: 5)
      assert_equal("hello", client.call(:echo, "hello"))
    end
  end

  def test_call_with_args_and_kwargs
    with_broker do
      start_server("echo", echo_handler)
      wait_for_backend("echo")

      client = Urpc::Client.new("echo", timeout: 5)
      assert_equal(7, client.call(:add, 3, 4))
      assert_equal("alice=30", client.call(:kw, name: "alice", age: 30))
    end
  end

  def test_call_propagates_handler_exception
    with_broker do
      start_server("echo", echo_handler)
      wait_for_backend("echo")

      client = Urpc::Client.new("echo", timeout: 5)
      e = assert_raises(ArgumentError) { client.call(:boom) }
      assert_equal("kaboom", e.message)
    end
  end

  def test_multiple_backends_share_per_key_queue
    with_broker do
      start_server("math", echo_handler)
      start_server("math", echo_handler)
      wait_for_backend("math", count: 2)

      client = Urpc::Client.new("math", timeout: 5)
      results = (1..6).map { client.call(:add, it, it) }
      assert_equal([2, 4, 6, 8, 10, 12], results)
    end
  end
end
