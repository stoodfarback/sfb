# frozen_string_literal: true

module Urpc
  class Client
    attr_accessor(:key, :timeout, :wait_for_server)

    def initialize(key, timeout: 0, wait_for_server: false)
      Urpc::Deadline.validate_duration!(timeout, name: "urpc timeout")
      Urpc::SubmitWriter.validate_wait_for_server!(wait_for_server)
      self.key = Urpc::Paths.new(key).key
      self.timeout = timeout
      self.wait_for_server = wait_for_server
    end

    def call(method_name, *args, **kargs, &block)
      stream(method_name, *args, **kargs, &block).result
    end

    def stream(method_name, *args, **kargs, &block)
      submit(method_name, args, kargs, cast: false, bidirectional: false, &block)
    end

    def cast(method_name, *args, **kargs, &block)
      submit(method_name, args, kargs, cast: true, bidirectional: false, &block)
      nil
    end

    def bidirectional(method_name, *args, **kargs, &block)
      submit(method_name, args, kargs, cast: false, bidirectional: true, &block)
    end

    def method_missing(method_name, *args, **kargs, &block)
      call(method_name, *args, **kargs, &block)
    end

    def respond_to_missing?(method_name, include_private = false)
      true
    end

    def submit(method_name, args, kargs, cast:, bidirectional:, &block)
      reject_block!(block)

      submission = Urpc::SubmitFrame::Submission.build(method_name, args, kargs, cast:, bidirectional:)
      writer = nil
      artifacts = nil
      submitted = false

      begin
        writer = Urpc::SubmitWriter.open(key, wait_for_server:)
        artifacts = Urpc::CallArtifacts.prepare(writer.paths, submission)
        writer.write(submission.frame)
        submitted = true

        return if submission.cast?

        reader = Urpc::FrameReader.new(artifacts.output_io, timeout:)
        if submission.bidirectional?
          Urpc::Bidirectional.new(reader, paths: writer.paths, id: submission.id)
        else
          Urpc::Stream.new(reader)
        end
      rescue Urpc::NoServerError
        cleanup_submission_failure(artifacts, submitted)
        return if submission.cast?

        raise
      rescue
        cleanup_submission_failure(artifacts, submitted)
        raise
      ensure
        if writer && !writer.closed?
          writer.close
        end
      end
    end

    def cleanup_submission_failure(artifacts, submitted)
      if artifacts && !submitted
        artifacts.cleanup_submission_failure!
      end
    end

    def reject_block!(block)
      if block
        raise(ArgumentError, "urpc calls do not accept blocks")
      end
    end
  end
end
