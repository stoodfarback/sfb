# frozen_string_literal: true

module Urpc
  class BrokerCall
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
      File.unlink(inbox_path) rescue nil if inbox_path
    end
  end
end
