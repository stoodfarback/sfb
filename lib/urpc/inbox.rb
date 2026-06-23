# frozen_string_literal: true

module Urpc
  class Inbox
    READ_CHUNK = 65_536
    OPEN_POLL_INTERVAL = 0.01
    READ_WAIT_INTERVAL = 0.1
    CLOSE_JOIN_TIMEOUT = 0.5

    attr_accessor(:owner, :path, :sync_messages, :state_lock, :state_cv, :ready, :disconnected,
      :close_requested, :reader_error, :reader_thread, :read_io, :unpacker)

    def initialize(owner:, path:)
      self.owner = owner
      self.path = path
      self.sync_messages = []
      self.state_lock = Mutex.new
      self.state_cv = ConditionVariable.new
      self.ready = false
      self.disconnected = false
      self.close_requested = false
      self.unpacker = MessagePack::DefaultFactory.unpacker
    end

    def start
      self.reader_thread = Thread.new { reader_loop }
      reader_thread.report_on_exception = false
      nil
    end

    def await_ready!(timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      state_lock.synchronize do
        loop do
          raise(reader_error) if reader_error
          return(true) if ready
          raise(EOFError, "inbox closed before ready") if disconnected
          raise(IOError, "inbox closed") if close_requested

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise(TimeoutException, "inbox ready timed out") if remaining <= 0
          state_cv.wait(state_lock, remaining)
        end
      end
    end

    def receive
      state_lock.synchronize do
        loop do
          raise(reader_error) if reader_error
          return sync_messages.shift if !sync_messages.empty?
          raise(EOFError, "inbox disconnected") if disconnected
          raise(IOError, "inbox closed") if close_requested
          state_cv.wait(state_lock)
        end
      end
    end

    def disconnected? = disconnected

    def close
      state_lock.synchronize do
        self.close_requested = true
        state_cv.broadcast
      end

      read_io&.close rescue nil
      if reader_thread&.alive?
        reader_thread.join(CLOSE_JOIN_TIMEOUT)
        reader_thread.kill if reader_thread.alive?
      end
      nil
    end

    def reader_loop
      self.read_io = File.open(path, File::RDONLY | File::NONBLOCK)
      wait_for_ready
      read_frames if ready
    rescue IOError, Errno::EBADF
      if !close_requested
        mark_disconnected
      end
    rescue => e
      mark_reader_error(e)
    ensure
      read_io&.close rescue nil
    end

    def wait_for_ready
      loop do
        return if close_requested

        chunk = read_io.read_nonblock(READ_CHUNK, exception: false)
        case chunk
        when :wait_readable
          read_io.wait_readable(READ_WAIT_INTERVAL)
        when nil
          sleep(OPEN_POLL_INTERVAL)
        else
          process_chunk(chunk)
          return if ready
        end
      end
    end

    def read_frames
      loop do
        return if close_requested

        if !read_io.wait_readable(READ_WAIT_INTERVAL)
          next
        end

        chunk = read_io.read_nonblock(READ_CHUNK, exception: false)
        case chunk
        when :wait_readable
          next
        when nil
          mark_disconnected
          return
        else
          process_chunk(chunk)
        end
      end
    end

    def process_chunk(chunk)
      unpacker.feed(chunk)
      unpacker.each do |frame|
        raise(MessagePack::UnpackError, "malformed inbox frame") if !Frames.valid_inbox_frame?(frame)
        dispatch_frame(frame)
      end
    end

    def dispatch_frame(frame)
      type, raw_payload = frame
      value = Frames.unpack_payload(raw_payload)
      raise(MessagePack::UnpackError, "inbox frame before ready") if type != :ready && !ready
      case type
      when :ready
        raise(MessagePack::UnpackError, "duplicate inbox ready frame") if ready
        raise(MessagePack::UnpackError, "invalid inbox ready payload") if !raw_payload.nil?
        mark_ready
      when :sync
        state_lock.synchronize do
          sync_messages << value
          state_cv.broadcast
        end
      when :async
        owner.receive_async(value)
      end
    end

    def mark_ready
      state_lock.synchronize do
        self.ready = true
        state_cv.broadcast
      end
    end

    def mark_disconnected
      should_callback = false
      state_lock.synchronize do
        should_callback = !disconnected && !close_requested
        self.disconnected = true
        state_cv.broadcast
      end
      if should_callback
        owner.on_disconnect
      end
    rescue => e
      mark_reader_error(e)
    end

    def mark_reader_error(error)
      state_lock.synchronize do
        self.reader_error = error
        self.disconnected = true
        state_cv.broadcast
      end

      begin
        if !owner.finished?
          owner.error(error)
        end
      rescue
        nil
      end
    end
  end
end
