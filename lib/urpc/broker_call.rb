# frozen_string_literal: true

module Urpc
  class BrokerCall
    attr_accessor(:call, :reply_io)

    def initialize(call:)
      self.call = call
    end

    def id = call.id
    def rpc_key = call.rpc_key
    def name = call.name
    def args = call.args
    def kargs = call.kargs
    def reply_path = call.reply_path
    def cast? = call.cast?
    def wait_for_server? = call.wait_for_server?
    def to_backend_request = call.to_backend_request

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
    rescue Errno::EPIPE
      close_reply_io
    end

    def close_reply_io
      reply_io&.close rescue nil
      self.reply_io = nil
    end

    def finish!
      cleanup_reply
    end

    def abandon!
      cleanup_reply
    end

    def cleanup_reply
      close_reply_io
      return if cast?
      File.unlink(reply_path) rescue nil
    end
  end
end
