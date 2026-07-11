# frozen_string_literal: true

require_relative("../lib/sfb")
require("minitest/autorun")

# see `unote sfb-test-snapshot` for notes on assert_snapshot
Sfb::Test::Snapshot.setup!

Sfb::Test::OutputCapture.setup!

module UrpcTestHelpers
  def with_urpc_root
    old_root = Urpc.configured_root

    Dir.mktmpdir do |dir|
      Urpc.set_root(dir)
      yield
    end
  ensure
    Urpc.configured_root = old_root
  end

  def with_urpc_server(key, handler)
    old_root = Urpc.configured_root

    Dir.mktmpdir("sfb-urpc") do |dir|
      Urpc.set_root(dir)
      server = Urpc::Server.new(key) do |req|
        begin
          result = handler.public_send(req.name, *req.args, **req.kargs)
          req.finish(result)
        rescue => e
          req.error(e)
        end
      end
      server_thread = Thread.new { server.run }
      yield
    ensure
      close_io(server)
      server_thread&.join(1)
      if server_thread&.alive?
        server_thread.kill
      end
    end
  ensure
    Urpc.configured_root = old_root
  end

  def close_io(object)
    if object && !object.closed?
      object.close
    end
  end
end

Minitest::Test.include(UrpcTestHelpers)
