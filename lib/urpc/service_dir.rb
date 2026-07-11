# frozen_string_literal: true

module Urpc
  class ServiceDir
    attr_accessor(:paths)

    def initialize(key)
      self.paths = Urpc::Paths.new(key)
    end

    def prepare!
      FileUtils.mkdir_p(paths.calls_dir)
      FileUtils.mkdir_p(paths.output_dir)
      FileUtils.mkdir_p(paths.input_dir)
      ensure_submit_fifo!
      paths
    end

    def acquire_server_lock!
      prepare!

      lock = File.open(paths.server_lock, File::RDWR | File::CREAT, 0o600)
      locked = lock.flock(File::LOCK_EX | File::LOCK_NB)

      if !locked
        lock.close
        raise("urpc service already running: #{paths.key}")
      end

      lock
    end

    def ensure_submit_fifo!
      if File.exist?(paths.submit_fifo) || File.symlink?(paths.submit_fifo)
        Urpc::Fifo.verify_path!(paths.submit_fifo)
        return
      end

      Urpc::Fifo.create(paths.submit_fifo)
    rescue Errno::EEXIST
      ensure_submit_fifo!
    end
  end
end
