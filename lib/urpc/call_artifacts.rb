# frozen_string_literal: true

module Urpc
  class CallArtifacts
    attr_accessor(:paths, :submission, :created_paths, :output_io)

    def initialize(paths, submission)
      self.paths = paths
      self.submission = submission
      self.created_paths = []
    end

    def self.prepare(paths, submission)
      artifacts = new(paths, submission)

      begin
        file_payload = submission.file_payload
        if file_payload
          artifacts.write_payload!(file_payload)
        end
        if submission.output?
          artifacts.create_output!
        end
        if submission.input?
          artifacts.create_input!
        end
        artifacts
      rescue
        artifacts.cleanup_submission_failure!
        raise
      end
    end

    def id
      submission.id
    end

    def write_payload!(payload)
      path = paths.call_file(id)

      file = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      created_paths << path
      file.binmode
      file.write(payload)
    ensure
      if file && !file.closed?
        file.close
      end
    end

    def create_output!
      path = paths.output_fifo(id)
      create_fifo!(path)
      self.output_io = Urpc::Fifo.open(path, File::RDONLY | File::NONBLOCK)
    end

    def create_input!
      create_fifo!(paths.input_fifo(id))
    end

    def create_fifo!(path)
      Urpc::Fifo.create(path)
      created_paths << path
    end

    def cleanup_submission_failure!
      close
      created_paths.reverse_each do |path|
        begin
          File.unlink(path)
        rescue Errno::ENOENT
        end
      end
      created_paths.clear
    end

    def close
      if output_io && !output_io.closed?
        output_io.close
      end
    end

    def closed?
      output_io.nil? || output_io.closed?
    end
  end
end
