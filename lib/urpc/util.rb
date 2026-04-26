# frozen_string_literal: true

require("fcntl")

module Urpc
  module Util
    def self.def_stream_to_basic(obj, method_name, &)
      obj.define_method(method_name) do |req|
        args = req.args
        kargs = req.kargs
        stream = req.stream
        ret = instance_exec(*args, **kargs, &)
        stream.return(ret)
        nil
      end
    end

    def self.clear_nonblock(io)
      flags = io.fcntl(Fcntl::F_GETFL)
      io.fcntl(Fcntl::F_SETFL, flags & ~File::NONBLOCK)
    end

    def self.open_reply_writer(path)
      io = File.new(path, File::WRONLY | File::NONBLOCK)
      if !io.stat.pipe?
        io.close rescue nil
        return
      end
      clear_nonblock(io)
      io
    rescue Errno::EACCES, Errno::EISDIR, Errno::ENOENT, Errno::ENXIO
      nil
    end
  end
end
