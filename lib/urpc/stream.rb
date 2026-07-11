# frozen_string_literal: true

module Urpc
  class Stream
    include(Enumerable)

    attr_accessor(:reader, :finished, :terminal_value, :terminal_error)

    def initialize(reader)
      self.reader = reader
      self.finished = false
      self.terminal_value = nil
      self.terminal_error = nil
    end

    def each
      return enum_for(:each) if !block_given?

      raise terminal_error if terminal_error
      return if finished?

      loop do
        frame = next_output_frame

        case frame.type
        when :data
          yield(frame.value)
        when :return
          finish_return!(frame.value)
          break
        when :error
          finish_error!(remote_error(frame.value))
        else
          finish_error!(RuntimeError.new("unexpected urpc output frame: #{frame.type}"))
        end
      end
    end

    def next_output_frame
      frame = reader.next_frame
      return frame if frame

      server_disconnected!
    rescue EOFError
      server_disconnected!
    rescue Urpc::TimeoutException => e
      finish_error!(e)
    end

    def result
      each {} if !finished?

      raise terminal_error if terminal_error
      terminal_value
    end

    def finished?
      finished
    end

    def close
      reader.close
    end

    def closed?
      reader.closed?
    end

    def finish_return!(value)
      self.finished = true
      self.terminal_value = value
      close
      value
    end

    def finish_error!(error)
      self.finished = true
      self.terminal_error = error
      close
      raise(error)
    end

    def server_disconnected!
      finish_error!(Urpc::ServerDisconnected.new("urpc server disconnected before terminal response"))
    end

    def remote_error(value)
      payload = begin
        Urpc::StreamFrame::ErrorPayload.decode(value)
      rescue ArgumentError => e
        return Urpc::RemoteException.new(e.message)
      end

      error = hydrate_remote_exception(payload.exception_name, payload.message, payload.backtrace)
      apply_remote_backtrace!(error, payload.backtrace)
      error
    end

    def hydrate_remote_exception(exception_name, message, backtrace)
      klass = remote_exception_class(exception_name)
      if klass
        if klass == Urpc::RemoteException
          return klass.new(message, backtrace, remote_exception: exception_name)
        end

        begin
          return klass.new(message)
        rescue
        end
      end

      Urpc::RemoteException.new("#{exception_name}: #{message}", backtrace, remote_exception: exception_name)
    end

    def remote_exception_class(exception_name)
      return if !exception_name.is_a?(String) || exception_name.empty?

      klass = Object.const_get(exception_name)
      return if !klass.is_a?(Class) || !(klass <= Exception)

      klass
    rescue NameError
      nil
    end

    def apply_remote_backtrace!(error, backtrace)
      error.set_backtrace(backtrace)
      error
    end
  end
end
