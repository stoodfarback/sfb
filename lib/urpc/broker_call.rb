# frozen_string_literal: true

module Urpc
  class BrokerCall
    TERMINAL_REPLY_DRAIN_TIMEOUT = 60
    TERMINAL_REPLY_DRAIN_CHUNK_BYTES = 64 * 1024

    attr_accessor(:call, :reply_io, :wait_deadline, :received_at, :inbox_path, :inbox_ready)

    def initialize(call:, received_at:)
      self.call = call
      self.received_at = received_at
      self.inbox_ready = false
    end

    def id = call.id
    def rpc_key = call.rpc_key
    def name = call.name
    def args = call.args
    def kargs = call.kargs
    def reply_path = call.reply_path
    def cast? = call.cast?
    def bidirectional? = call.bidirectional?
    def wait_for_server? = call.wait_for_server?
    def wait_for_server_seconds = call.wait_for_server_seconds

    def to_backend_request
      call.to_backend_request.merge(
        bidirectional: bidirectional?,
        inbox_path: bidirectional? ? ensure_inbox_path : nil,
      )
    end

    def wanted?
      cast? || File.pipe?(reply_path)
    end

    def ensure_reply_open
      return true if cast?
      return false if !wanted?

      self.reply_io ||= Util.open_reply_writer(reply_path)
      !!reply_io
    end

    def reply_open?
      !!reply_io
    end

    def write_reply_frame(frame)
      return if !reply_io
      reply_io.write(MessagePack.pack(frame))
      reply_io.flush
    rescue Errno::EPIPE
      close_reply_io
    end

    def write_response_frame(frame)
      if Frames::TERMINAL_TYPES.include?(frame[0])
        write_terminal_reply_frame(frame)
      else
        write_reply_frame(frame)
      end
    end

    def write_terminal_reply_frame(frame)
      return if !reply_io

      bytes = MessagePack.pack(frame)
      written = reply_io.write_nonblock(bytes, exception: false)
      return if written == bytes.bytesize

      remaining = written == :wait_writable ? bytes : bytes.byteslice(written..)
      drain_reply_io(remaining)
    rescue Errno::EPIPE, Errno::EBADF, IOError
      close_reply_io
    end

    def drain_reply_io(bytes)
      io = reply_io
      self.reply_io = nil
      thread = Thread.new do
        begin
          drain_reply_bytes(io, bytes, monotonic_now + TERMINAL_REPLY_DRAIN_TIMEOUT)
        rescue Errno::EPIPE, Errno::EBADF, IOError
          nil
        ensure
          io.close rescue nil
        end
      end
      thread.report_on_exception = false
      nil
    end

    def drain_reply_bytes(io, bytes, deadline)
      offset = 0
      while offset < bytes.bytesize
        remaining = deadline - monotonic_now
        if remaining <= 0
          warn_terminal_reply_drain_timeout(offset, bytes.bytesize)
          return
        end

        if !io.wait_writable(remaining)
          warn_terminal_reply_drain_timeout(offset, bytes.bytesize)
          return
        end

        chunk = bytes.byteslice(offset, TERMINAL_REPLY_DRAIN_CHUNK_BYTES)
        written = io.write_nonblock(chunk, exception: false)
        next if written == :wait_writable
        next if written == 0
        offset += written
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def warn_terminal_reply_drain_timeout(offset, total)
      remaining = total - offset
      warn("urpc broker: terminal reply drain timed out after #{TERMINAL_REPLY_DRAIN_TIMEOUT}s for #{rpc_key}##{name} #{id[0, 8]} with #{remaining} of #{total} bytes remaining")
    end

    def close_reply_io
      reply_io&.close rescue nil
      self.reply_io = nil
    end

    def ensure_inbox
      return true if !bidirectional?
      path = ensure_inbox_path
      return true if File.pipe?(path)
      FileUtils.mkdir_p(Urpc.inboxes_dir)
      File.mkfifo(path)
      true
    end

    def ensure_inbox_path
      self.inbox_path ||= Call.inbox_path(id)
    end

    def mark_inbox_ready!
      raise(MessagePack::UnpackError, "duplicate inbox_ready frame") if inbox_ready
      self.inbox_ready = true
    end

    def finish!
      cleanup
    end

    def abandon!
      cleanup
    end

    def cleanup
      close_reply_io
      return if cast?
      File.unlink(reply_path) rescue nil
      if inbox_path
        File.unlink(inbox_path) rescue nil
      end
    end

    class ReplySink
      attr_accessor(:call)

      def initialize(call)
        self.call = call
      end

      def write_response(type, value)
        call.write_response_frame(Frames.frame(type, value))
      end

      def write_error(exception)
        call.write_terminal_reply_frame(Frames.error_frame(exception))
      end
    end
  end
end
