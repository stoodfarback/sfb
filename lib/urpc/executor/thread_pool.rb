# frozen_string_literal: true

module Urpc::Executor
  class ThreadPool < Pool
    STOP = Object.new.freeze
    CLOSED_RESERVATION = Object.new.freeze

    attr_accessor(:idle, :mailboxes, :closed)

    def start(...)
      super
      self.idle = Thread::Queue.new
      self.mailboxes = []
      self.closed = false

      size.times do
        mailbox = Thread::Queue.new
        thread = Thread.new { worker_loop(mailbox) }
        thread.abort_on_exception = true
        mailboxes << mailbox
        idle << mailbox
      end
      self
    end

    def reserve
      reservation = idle.pop
      if reservation.equal?(CLOSED_RESERVATION)
        raise(IOError, "urpc thread pool is closed")
      end
      reservation
    end

    def submit(mailbox, accepted)
      mailbox << accepted
      nil
    end

    def worker_loop(mailbox)
      loop do
        accepted = mailbox.pop
        return if accepted.equal?(STOP)

        execute(accepted)
        return if closed

        idle << mailbox
      end
    end

    def close
      return if closed

      self.closed = true
      idle << CLOSED_RESERVATION
      mailboxes.each { it << STOP }
      nil
    end
  end
end
