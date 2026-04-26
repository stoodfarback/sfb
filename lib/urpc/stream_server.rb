# frozen_string_literal: true

module Urpc
  class StreamServer
    attr_accessor(:rpc_key, :handler, :shutdown, :sock)

    def initialize(rpc_key, handler)
      self.rpc_key = rpc_key
      self.handler = handler
      self.shutdown = false
    end

    BACKOFF_BASE = 0.1
    BACKOFF_CAP  = 5.0

    def run
      backoff = BACKOFF_BASE
      loop do
        break if shutdown
        begin
          self.sock = UNIXSocket.open(Urpc.broker_sock)
          sock.write(MessagePack.pack(rpc_key))
          unpacker = MessagePack::DefaultFactory.unpacker(sock)
          backoff = BACKOFF_BASE
          loop do
            break if shutdown
            run_one(unpacker)
          end
        rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET,
               Errno::EPIPE, IOError, MessagePack::UnpackError => e
          warn("urpc server [#{rpc_key}]: connection lost: #{e.class} #{e.message}, reconnecting...")
        ensure
          sock&.close rescue nil
          self.sock = nil
        end
        break if shutdown
        jitter = backoff * (0.5 + (rand * 0.5))
        sleep(jitter)
        backoff = [backoff * 2, BACKOFF_CAP].min
      end
    end

    def run_one(unpacker)
      req_data = unpacker.read
      raise(MessagePack::UnpackError, "malformed broker request frame") if !valid_request_frame?(req_data)

      stream = ResponseStream.new(sink: ResponseStream::Sinks::Socket.new(sock))
      req = Req.new(args: req_data[:args], kargs: req_data[:kargs], stream: stream)

      begin
        handler.send(req_data[:name], req)
      rescue => e
        stream.error(e) if !stream.is_finished
        return
      end

      if !stream.is_finished
        stream.error("stream not finished but method returned")
      end
    end

    def valid_request_frame?(req)
      req.is_a?(Hash) &&
        req[:name].is_a?(Symbol) &&
        req[:args].is_a?(Array) &&
        req[:kargs].is_a?(Hash)
    end
  end
end
