# frozen_string_literal: true

require_relative("test_helper")

class TestLsbClient < Minitest::Test
  def test_basic
    project_name = "sfb"
    project_id = "nzsdzv5zd7r5kcf8prbxyhzics10fm92rp07gbyu5mktyfzv49"
    client = Sfb::LsbClient.new(project_id:, project_name:)
    assert_equal("pong", client.fetch("ping"))
  end

  def test_exchange_helper_success
    with_unix_server do |socket_path, server|
      thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        client.write("{\"ok\":true}\n")
      ensure
        client&.close
      end

      line = Sfb::LsbClient::ExchangeHelper.exchange(
        payload: "{}\n",
        socket_path:,
        max_line_bytes: 1024,
        timeout_seconds: 1
      )

      assert_equal("{\"ok\":true}\n", line)
      thread.join
    end
  end

  def test_exchange_helper_ignores_extra_bytes_after_newline
    with_unix_server do |socket_path, server|
      thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        client.write("{\"ok\":true}\nTRAILING")
      ensure
        client&.close
      end

      line = Sfb::LsbClient::ExchangeHelper.exchange(
        payload: "{}\n",
        socket_path:,
        max_line_bytes: 1024,
        timeout_seconds: 1
      )

      assert_equal("{\"ok\":true}\n", line)
      thread.join
    end
  end

  def test_exchange_helper_partial_write
    with_unix_server do |socket_path, server|
      thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        client.write("{\"ok\":true}\n")
      ensure
        client&.close
      end

      payload = ("a" * 65_536) + "\n"
      line = Sfb::LsbClient::ExchangeHelper.exchange(
        payload:,
        socket_path:,
        max_line_bytes: 1024,
        timeout_seconds: 1
      )

      assert_equal("{\"ok\":true}\n", line)
      thread.join
    end
  end

  def test_fetch_caches_success
    project_name = "sfb"
    project_id = "nzsdzv5zd7r5kcf8prbxyhzics10fm92rp07gbyu5mktyfzv49"
    client = Sfb::LsbClient.new(project_id:, project_name:)

    calls = 0
    payload = Base64.strict_encode64("secret")
    client.define_singleton_method(:exchange) do |_request|
      calls += 1
      "{\"ok\":true,\"value_b64\":\"#{payload}\"}\n"
    end

    assert_equal("secret", client.fetch("token"))
    assert_equal("secret", client.fetch("token"))
    assert_equal(1, calls)
  end

  def test_fetch_does_not_cache_denied
    project_name = "sfb"
    project_id = "nzsdzv5zd7r5kcf8prbxyhzics10fm92rp07gbyu5mktyfzv49"
    client = Sfb::LsbClient.new(project_id:, project_name:)

    calls = 0
    client.define_singleton_method(:exchange) do |_request|
      calls += 1
      "{\"ok\":false}\n"
    end

    assert_raises(Sfb::LsbClient::Denied) { client.fetch("token") }
    assert_raises(Sfb::LsbClient::Denied) { client.fetch("token") }
    assert_equal(2, calls)
  end

  def test_exchange_helper_response_too_large
    with_unix_server do |socket_path, server|
      thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        client.write("12345")
      ensure
        client&.close
      end

      error = assert_raises(Sfb::LsbClient::ProtocolError) do
        Sfb::LsbClient::ExchangeHelper.exchange(
          payload: "{}\n",
          socket_path:,
          max_line_bytes: 4,
          timeout_seconds: 1
        )
      end

      assert_match(/Response too large or missing newline/, error.message)
      thread.join
    end
  end

  def test_exchange_helper_timeout_waiting_for_response
    with_unix_server do |socket_path, server|
      thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        sleep(0.3)
      ensure
        client&.close
      end

      error = assert_raises(Sfb::LsbClient::ProtocolError) do
        Sfb::LsbClient::ExchangeHelper.exchange(
          payload: "{}\n",
          socket_path:,
          max_line_bytes: 1024,
          timeout_seconds: 0.1
        )
      end

      assert_match(/Timed out waiting for broker response/, error.message)
      thread.join
    end
  end

  private

  def with_unix_server
    Dir.mktmpdir("sfb-lsb") do |dir|
      socket_path = File.join(dir, "lsb.sock")
      server = UNIXServer.new(socket_path)
      yield(socket_path, server)
    ensure
      server&.close
    end
  end
end
