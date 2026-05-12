# frozen_string_literal: true

module Urpc
  class BidirectionalHandler < CallHandler
    # URPC ping-pong round-trip is typically <1ms, so 1s is a reasonable default.
    INBOX_OPEN_TIMEOUT = 1.0

    attr_accessor(:inbox)

    def handle!
      setup_inbox!
      super
    ensure
      inbox&.close
    end

    def setup_inbox!
      self.inbox = Inbox.new(owner: self)
      inbox.start
      send_frame(:inbox, inbox.path)
      inbox.await_open!(timeout: INBOX_OPEN_TIMEOUT)
    end

    def receive = inbox.receive
    def disconnected? = inbox.disconnected?

    def receive_async(_value); end
    def on_disconnect; end
  end
end
