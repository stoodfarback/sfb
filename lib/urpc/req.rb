# frozen_string_literal: true

module Urpc
  class Req
    INPUT_TYPES = [:sync, :async].freeze

    attr_accessor(:call, :finished, :response_mutex)

    def initialize(call)
      self.call = call
      self.finished = false
      self.response_mutex = Mutex.new
    end

    def name
      call.submit.name
    end

    def args
      call.submit.args
    end

    def kargs
      call.submit.kargs
    end

    def cast?
      call.cast?
    end

    def bidirectional?
      call.bidirectional?
    end

    def data(value)
      response_mutex.synchronize do
        ensure_open!
        return if cast?
        call.output.write_frame(:data, value)
      end
      nil
    rescue Errno::EPIPE => e
      client_disconnected!(e)
    end

    def finish(value = nil)
      terminal_response(:return, value, if_open: false)
    end

    def finish_if_open(value = nil)
      terminal_response(:return, value, if_open: true)
    end

    def error(exception)
      terminal_response(:error, exception, if_open: false)
    end

    def error_if_open(exception)
      terminal_response(:error, exception, if_open: true)
    end

    def finished?
      finished
    end

    def next_input
      ensure_open!
      if !bidirectional?
        raise(IOError, "urpc request has no input stream")
      end

      frame = call.input_reader.next_frame
      if !frame
        raise(EOFError, "urpc input disconnected")
      end
      if !INPUT_TYPES.include?(frame.type)
        raise("unexpected urpc input frame: #{frame.type}")
      end

      frame
    end

    def close
      response_mutex.synchronize do
        return if finished?

        self.finished = true
        call.close
      end
      nil
    end

    def write_terminal(type, value)
      ensure_open!

      if cast?
        self.finished = true
        call.close
        return
      end

      bytes = Urpc::StreamFrame.pack(type, value)
      begin
        call.output.write(bytes)
      ensure
        self.finished = true
        call.close
      end
      nil
    end

    def terminal_response(type, value, if_open:)
      response_mutex.synchronize do
        return false if if_open && finished?

        payload = type == :error ? Urpc::StreamFrame::ErrorPayload.encode(value) : value
        write_terminal(type, payload)
        if_open ? true : nil
      end
    rescue Errno::EPIPE => e
      client_disconnected!(e)
    end

    def ensure_open!
      if finished?
        raise(IOError, "urpc request is finished")
      end
    end

    def client_disconnected!(error)
      close
      raise(Urpc::ClientDisconnected, error.message)
    end
  end
end
