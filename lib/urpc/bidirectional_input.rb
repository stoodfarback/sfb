# frozen_string_literal: true

module Urpc
  class BidirectionalInput
    CLOSE_JOIN_TIMEOUT = 0.5

    attr_accessor(:req, :owner, :messages, :reader_thread, :state_mutex, :terminal, :closed, :disconnected)

    def initialize(req, owner:)
      self.req = req
      self.owner = owner
      self.messages = Thread::Queue.new
      self.reader_thread = nil
      self.state_mutex = Mutex.new
      self.terminal = nil
      self.closed = false
      self.disconnected = false
    end

    def start
      self.reader_thread = Thread.new { reader_loop }
      reader_thread.report_on_exception = false
      reader_thread.abort_on_exception = true
      self
    end

    def receive
      message = messages.pop
      if message
        type, value = message
        if type != :sync
          raise("unexpected urpc input message: #{type.inspect}")
        end
        return value
      end

      type, value = state_mutex.synchronize { terminal }
      case type
      when :disconnected
        raise(EOFError, "urpc input disconnected")
      when :closed
        raise(IOError, "urpc input is closed")
      when :error
        raise(value)
      else
        raise("urpc input queue closed without a terminal state")
      end
    end

    def disconnected?
      state_mutex.synchronize { disconnected }
    end

    def closed?
      state_mutex.synchronize { closed }
    end

    def close
      first_close = state_mutex.synchronize do
        if closed
          false
        else
          self.closed = true
          publish_terminal_locked(:closed, nil)
          true
        end
      end
      if !first_close
        return
      end

      if req.call.input_reader && !req.call.input_reader.closed?
        req.call.input_reader.close
      end

      if reader_thread && reader_thread != Thread.current && reader_thread.alive?
        reader_thread.join(CLOSE_JOIN_TIMEOUT)
        reader_thread.kill if reader_thread.alive?
      end
      nil
    end

    def reader_loop
      loop do
        return if closed?

        frame = req.next_input
        case frame.type
        when :sync
          if !enqueue_sync(frame.value)
            return
          end
        when :async
          owner.receive_async(frame.value)
        end
      end
    rescue EOFError
      mark_disconnected
    rescue IOError, Errno::EBADF
      if !req.finished?
        mark_disconnected
      end
    rescue => e
      mark_error(e)
    end

    def mark_disconnected
      notify = state_mutex.synchronize do
        if closed || disconnected
          false
        else
          self.disconnected = true
          true
        end
      end
      if !notify
        return
      end

      owner.on_disconnect
      publish_terminal(:disconnected, nil)
    rescue => e
      mark_error(e)
    end

    def mark_error(error)
      if !publish_terminal(:error, error)
        return
      end

      begin
        req.error_if_open(error)
      rescue Urpc::ClientDisconnected
        nil
      end
    end

    def enqueue_sync(value)
      state_mutex.synchronize do
        if terminal
          return false
        end

        messages << [:sync, value]
        true
      end
    end

    def publish_terminal(type, value)
      state_mutex.synchronize { publish_terminal_locked(type, value) }
    end

    def publish_terminal_locked(type, value)
      if terminal
        return false
      end

      self.terminal = [type, value]
      messages.close
      true
    end
  end
end
