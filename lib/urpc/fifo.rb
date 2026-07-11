# frozen_string_literal: true

module Urpc
  module Fifo
    MODE = 0o600

    def self.create(path)
      File.mkfifo(path, MODE)
      path
    end

    def self.open(path, flags)
      io = File.open(path, flags)

      begin
        verify_io!(io, path)
      rescue
        if !io.closed?
          io.close
        end
        raise
      end

      io
    end

    def self.verify_io!(io, path)
      if !io.stat.pipe?
        raise("#{path} is not a FIFO")
      end
      io
    end

    def self.verify_path!(path)
      if !File.lstat(path).pipe?
        raise("#{path} is not a FIFO")
      end
      path
    end
  end
end
