# frozen_string_literal: true

module Urpc
  class Bidirectional
    include(Enumerable)

    attr_accessor(:stream, :paths, :id, :input_stream, :input_closed, :input_mutex)

    def initialize(reader, paths:, id:)
      self.stream = Urpc::Stream.new(reader)
      self.paths = paths
      self.id = id
      self.input_stream = nil
      self.input_closed = false
      self.input_mutex = Mutex.new
    end

    def await_input
      map_input_attachment_errors do
        input_mutex.synchronize { attach_input! }
      end
    end

    def attach_input!
      return input_stream if input_stream
      if input_closed
        raise(IOError, "urpc input stream is closed")
      end

      frame = stream.reader.next_frame
      if !frame
        raise(Urpc::ServerDisconnected, "urpc server disconnected before input ready")
      end
      if frame.type != :input_ready
        raise("expected INPUT_READY, got #{frame.type}")
      end

      self.input_stream = Urpc::InputStream.open(paths, id:)
    end

    def input_open?
      input_mutex.synchronize { !!(input_stream && input_stream.open?) }
    end

    def input_closed?
      input_mutex.synchronize { input_closed }
    end

    def send_sync(value)
      await_input.send_sync(value)
    end

    def send_async(value)
      await_input.send_async(value)
    end

    def close_input
      map_input_attachment_errors do
        input_mutex.synchronize do
          return if input_closed && !input_stream

          attach_input!.close
          self.input_stream = nil
          self.input_closed = true
          nil
        end
      end
    end

    def each
      return enum_for(:each) if !block_given?

      begin
        await_input if !stream.finished? && !input_closed?
        stream.each do |value|
          yield(value)
        end
      ensure
        close_input_after_terminal!
      end

      nil
    end

    def result
      return stream.result if stream.finished?

      await_input if !input_closed?
      stream.result
    ensure
      close_input_after_terminal!
    end

    def finished?
      stream.finished?
    end

    def close
      input_mutex.synchronize do
        if input_stream
          input_stream.close
          self.input_stream = nil
        end
        self.input_closed = true
      end
      stream.close
    end

    def closed?
      stream.closed?
    end

    def close_input_after_terminal!
      return if !stream.finished?

      input_mutex.synchronize do
        if input_stream
          input_stream.close
          self.input_stream = nil
        end
        self.input_closed = true
      end
    end

    def finish_error!(error)
      stream.finish_error!(error)
    ensure
      close_input_after_terminal!
    end

    def map_input_attachment_errors
      yield
    rescue EOFError
      finish_error!(Urpc::ServerDisconnected.new("urpc server disconnected before input ready"))
    rescue Urpc::ServerDisconnected, Urpc::TimeoutException => e
      finish_error!(e)
    end
  end
end
