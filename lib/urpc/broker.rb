# frozen_string_literal: true

require("fcntl")

module Urpc
  class Broker
    HANDSHAKE_DEADLINE = 5.0

    SWEEP_INTERVAL = 300
    RESPONSE_EXPIRY = 3600
    MONITOR_PAYLOAD_PREVIEW_LENGTH = 80
    MONITOR_RESPONSE_TYPES = {
      data: "DAT",
      inbox: "INB",
      return: "RET",
      error: "ERR",
    }.freeze

    attr_accessor(:queues_by_key, :backends_by_key, :in_flight_by_key, :active_ids, :wait_calls_by_id, :wait_cv, :next_wait_deadline,
      :internal_backends_by_key, :state_lock, :in_read, :in_dummy_write,
      :sock_server, :reader_thread, :accept_thread, :sweeper_thread, :wait_expiry_thread, :shutdown, :stopped, :broker_lock, :owns_broker_lock, :filesystem_ready,
      :monitor_server, :monitor_accept_thread, :monitors)

    def initialize
      self.queues_by_key = {}
      self.backends_by_key = {}
      self.internal_backends_by_key = {}
      self.in_flight_by_key = Hash.new(0)
      self.active_ids = {}
      self.wait_calls_by_id = {}
      self.wait_cv = ConditionVariable.new
      self.next_wait_deadline = nil
      self.state_lock = Mutex.new
      self.shutdown = false
      self.stopped = false
      self.owns_broker_lock = false
      self.filesystem_ready = false
      self.monitors = []
    end

    def run
      setup_filesystem
      open_in_fifo
      open_broker_sock
      register_introspection_backend
      start_reader_thread
      start_accept_thread
      start_monitor_server
      start_sweeper_thread
      start_wait_expiry_thread
      sleep(1) until shutdown
    end

    def stop
      return if stopped
      self.stopped = true
      state_lock.synchronize do
        self.shutdown = true
        wait_cv.broadcast
      end

      begin
        signal_workers_stop
      rescue
        nil
      end

      in_dummy_write&.close rescue nil
      in_read&.close rescue nil
      sock_server&.close rescue nil
      monitor_server&.close rescue nil

      state_lock.synchronize do
        backends_by_key.each_value do |list|
          list.each { it.sock.close rescue nil }
        end
      end

      reader_thread&.join(1) rescue nil
      accept_thread&.join(1) rescue nil
      monitor_accept_thread&.join(1) rescue nil
      sweeper_thread&.join(1) rescue nil
      wait_expiry_thread&.join(1) rescue nil

      threads = state_lock.synchronize do
        backends_by_key.values.flatten.map(&:worker_thread) +
          internal_backends_by_key.values.flatten.map(&:worker_thread)
      end

      threads.each { it&.join(1) rescue nil }

      state_lock.synchronize do
        monitors.each { it.close rescue nil }
      end

      if owns_broker_lock && filesystem_ready
        remove_stale(Urpc.broker_sock)
        remove_stale(Urpc.monitor_sock)
        remove_stale(Urpc.in_fifo)
      end

      broker_lock&.close rescue nil
      self.broker_lock = nil
      self.owns_broker_lock = false
    end

    def signal_workers_stop
      state = state_lock.synchronize do
        {
          queues: queues_by_key.dup,
          backend_counts: backends_by_key.transform_values(&:size),
          internal_counts: internal_backends_by_key.transform_values(&:size),
        }
      end

      state[:queues].each do |key, q|
        total = (state[:backend_counts][key] || 0) + (state[:internal_counts][key] || 0)
        total = 1 if total == 0
        total.times { q << nil }
      end
    end

    def setup_filesystem
      FileUtils.mkdir_p(Urpc.root)

      lock_path = File.join(Urpc.root, "broker.lock")
      self.broker_lock = File.open(lock_path, File::RDWR | File::CREAT)
      if !broker_lock.flock(File::LOCK_EX | File::LOCK_NB)
        broker_lock&.close rescue nil
        self.broker_lock = nil
        raise("urpc broker already running (lock held): #{lock_path}")
      end

      self.owns_broker_lock = true

      clean_dir(Urpc.requests_dir)
      clean_dir(Urpc.replies_dir)
      remove_stale(Urpc.broker_sock)
      remove_stale(Urpc.monitor_sock)
      remove_stale(Urpc.in_fifo)
      File.mkfifo(Urpc.in_fifo)

      self.filesystem_ready = true
    end

    def remove_stale(path)
      return if !File.exist?(path) && !File.symlink?(path)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end

    def clean_dir(dir)
      FileUtils.mkdir_p(dir)
      Dir.children(dir).each {|child| File.unlink(File.join(dir, child)) rescue nil }
    end

    def open_in_fifo
      self.in_read = File.open(Urpc.in_fifo, File::RDONLY | File::NONBLOCK)
      self.in_dummy_write = File.open(Urpc.in_fifo, File::WRONLY)
      flags = in_read.fcntl(Fcntl::F_GETFL)
      in_read.fcntl(Fcntl::F_SETFL, flags & ~File::NONBLOCK)
    end

    def open_broker_sock
      self.sock_server = UNIXServer.new(Urpc.broker_sock)
    end

    def start_reader_thread
      self.reader_thread = Thread.new { reader_loop }
      reader_thread.report_on_exception = false
    end

    def start_accept_thread
      self.accept_thread = Thread.new { accept_loop }
      accept_thread.report_on_exception = false
    end

    def start_monitor_server
      self.monitor_server = UNIXServer.new(Urpc.monitor_sock)
      self.monitor_accept_thread = Thread.new { monitor_accept_loop }
      monitor_accept_thread.report_on_exception = false
    end

    def monitor_accept_loop
      loop do
        sock = monitor_server.accept
        state_lock.synchronize { monitors << sock }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def queue_for(key)
      state_lock.synchronize { queues_by_key[key] ||= Queue.new }
    end

    def backend_count(key)
      state_lock.synchronize do
        backend_count_locked(key)
      end
    end

    def backend_count_locked(key)
      (backends_by_key[key] || []).size + (internal_backends_by_key[key] || []).size
    end

    def stats_snapshot
      state_lock.synchronize do
        backends = {}
        (backends_by_key.keys | internal_backends_by_key.keys | queues_by_key.keys | in_flight_by_key.keys).each do |k|
          backends[k] = (backends_by_key[k] || []).size + (internal_backends_by_key[k] || []).size
        end

        queue_depths = {}
        queues_by_key.each do |k, q|
          queue_depths[k] = q.size
        end

        in_flight = {}
        in_flight_by_key.each do |k, n|
          in_flight[k] = n
        end

        {
          backends: backends,
          queue_depths: queue_depths,
          in_flight: in_flight,
        }
      end
    end

    def in_flight_inc(key)
      state_lock.synchronize { in_flight_by_key[key] += 1 }
    end

    def in_flight_dec(key)
      state_lock.synchronize { in_flight_by_key[key] -= 1 }
    end

    def register_introspection_backend
      backend = InternalBackend.new(key: RESERVED_KEY, broker: self, handler: Introspection.new(self))
      state_lock.synchronize do
        queues_by_key[RESERVED_KEY] ||= Queue.new
        (internal_backends_by_key[RESERVED_KEY] ||= []) << backend
      end
      backend.start
    end

    def unregister_internal_backend(backend)
      key = backend.key
      drained_calls = state_lock.synchronize do
        list = internal_backends_by_key[key] || []
        list.delete(backend)
        internal_backends_by_key.delete(key) if list.empty?
        drain_queued_calls_if_no_backends_locked(key)
      end

      synthesize_no_server_for_drained_calls(key, drained_calls)
    end

    def start_sweeper_thread
      self.sweeper_thread = Thread.new { sweeper_loop }
      sweeper_thread.report_on_exception = false
    end

    def sweeper_loop
      next_sweep = monotonic_now + SWEEP_INTERVAL
      loop do
        state_lock.synchronize do
          loop do
            return if shutdown
            remaining = next_sweep - monotonic_now
            break if !remaining.positive?
            wait_cv.wait(state_lock, remaining)
          end
        end

        sweep!
        next_sweep = monotonic_now + SWEEP_INTERVAL
      end
    end

    def start_wait_expiry_thread
      self.wait_expiry_thread = Thread.new { wait_expiry_loop }
      wait_expiry_thread.report_on_exception = false
    end

    def wait_expiry_loop
      loop do
        expired_calls = state_lock.synchronize do
          loop do
            return if shutdown

            now = monotonic_now
            self.next_wait_deadline ||= next_wait_deadline_locked
            if !next_wait_deadline
              wait_cv.wait(state_lock)
              next
            end

            remaining = next_wait_deadline - now
            if remaining.positive?
              wait_cv.wait(state_lock, remaining)
              next
            end

            calls = expire_wait_calls_locked(now)
            self.next_wait_deadline = nil
            break(calls)
          end
        end

        synthesize_wait_expired_calls(expired_calls)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def next_wait_deadline_locked
      wait_calls_by_id.values.filter_map do |call|
        active_ids.key?(call.id) ? call.wait_deadline : nil
      end.min
    end

    def expire_wait_calls_locked(now)
      expired_calls = []
      stale_ids = []
      wait_calls_by_id.each_value do |call|
        if !active_ids.key?(call.id)
          stale_ids << call.id
          next
        end

        next if !call.wait_deadline || call.wait_deadline > now
        expired_calls << call
      end

      stale_ids.each { wait_calls_by_id.delete(it) }
      expired_calls.each do |call|
        wait_calls_by_id.delete(call.id)
        active_ids.delete(call.id)
      end
      expired_calls.map(&:rpc_key).uniq.each do |key|
        compact_queue_locked(key) if backend_count_locked(key) == 0
      end
      expired_calls
    end

    def compact_queue_locked(key)
      q = queues_by_key[key]
      return if !q

      survivors = []
      loop do
        begin
          call = q.pop(true)
        rescue ThreadError
          break
        end
        break if !call
        survivors << call if active_ids.key?(call.id)
      end

      if survivors.empty?
        queues_by_key.delete(key)
      else
        new_q = Queue.new
        survivors.each { new_q << it }
        queues_by_key[key] = new_q
      end
    end

    def sweep!(expiry: RESPONSE_EXPIRY)
      now = Time.now
      active = state_lock.synchronize { active_ids.keys.to_h { [it, true] } }

      # TODO: expire queued `wait_for_server` calls whose `reply_path` is gone.
      sweep_dir(Urpc.requests_dir, ".msgpack", now:, expiry:, active:)
      sweep_dir(Urpc.replies_dir, ".fifo", now:, expiry:, active:)
    end

    def sweep_dir(dir, ext, now:, expiry:, active:)
      Dir.children(dir).each do |name|
        next if !name.end_with?(ext)
        id = name.delete_suffix(ext)
        next if id !~ ID_RE
        next if active[id]
        path = File.join(dir, name)
        begin
          st = File.stat(path)
        rescue Errno::ENOENT
          next
        end
        age = now - st.mtime
        next if age < expiry
        begin
          File.unlink(path)
          warn("urpc broker: sweep reclaimed #{path}")
        rescue Errno::ENOENT
          nil
        end
      end
    end

    def reader_loop
      loop do
        frame = read_submit_frame
        break if !frame
        process_submission(frame)
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def read_submit_frame
      # getbyte primes Ruby's IO buffer with one read(8192) syscall; subsequent
      # IO#read(n) calls drain the buffer instead of issuing their own syscalls.
      version = in_read.getbyte
      return if !version
      abort_broker("invalid submit wire version: #{version}") if version != SubmitFrame::SUBMIT_WIRE_VERSION

      flags = in_read.getbyte
      return if !flags
      abort_broker("unknown submit flag bits: 0x%02x" % flags) if (flags & ~SubmitFrame::KNOWN_SUBMIT_FLAGS) != 0

      id_bin = read_exact(SubmitFrame::WIRE_ID_BYTES)
      return if !id_bin
      id_hex = id_bin.unpack1("H*")

      wait_mode = in_read.getbyte
      return if !wait_mode
      wait_for_server =
        case wait_mode
        when SubmitFrame::WAIT_NO_SERVER
          false
        when SubmitFrame::WAIT_FOREVER
          true
        when SubmitFrame::WAIT_TIMEOUT_MS
          ms_bytes = read_exact(SubmitFrame::WAIT_TIMEOUT_BYTES)
          return if !ms_bytes
          ms_bytes.unpack1("N") / 1000.0
        else
          abort_broker("invalid submit wait mode: #{wait_mode}")
        end

      rpc_key_len = in_read.getbyte
      return if !rpc_key_len
      abort_broker("invalid submit rpc_key length: #{rpc_key_len}") if rpc_key_len < 1 || rpc_key_len > SubmitFrame::WIRE_NAME_MAX
      rpc_key_bytes = read_exact(rpc_key_len)
      return if !rpc_key_bytes
      rpc_key = decode_submit_name("rpc_key", rpc_key_bytes)

      method_len = in_read.getbyte
      return if !method_len
      abort_broker("invalid submit method length: #{method_len}") if method_len < 1 || method_len > SubmitFrame::WIRE_NAME_MAX
      method_bytes = read_exact(method_len)
      return if !method_bytes
      method_name = decode_submit_name("method", method_bytes)

      inline = (flags & SubmitFrame::SUBMIT_FLAG_INLINE) != 0
      cast = (flags & SubmitFrame::SUBMIT_FLAG_CAST) != 0

      header_bytes = SubmitFrame::SUBMIT_VERSION_BYTES + SubmitFrame::SUBMIT_FLAGS_BYTES + SubmitFrame::WIRE_ID_BYTES + 1
      header_bytes += SubmitFrame::WAIT_TIMEOUT_BYTES if wait_mode == SubmitFrame::WAIT_TIMEOUT_MS
      header_bytes += 1 + rpc_key_len + 1 + method_len

      body = nil
      if inline
        body_len_bytes = read_exact(2)
        return if !body_len_bytes
        body_len = body_len_bytes.unpack1("n")
        total_frame = header_bytes + 2 + body_len
        abort_broker("inline submit frame too large: #{total_frame}") if total_frame > SubmitFrame::INLINE_FRAME_MAX
        abort_broker("inline submit body length zero") if body_len == 0
        body = read_exact(body_len)
        return if !body
      end

      {
        id_hex: id_hex,
        rpc_key: rpc_key,
        method_name: method_name,
        cast: cast,
        wait_for_server: wait_for_server,
        inline: inline,
        body: body,
      }
    end

    def read_exact(n)
      buf = in_read.read(n)
      return if !buf || buf.bytesize < n
      buf
    end

    def decode_submit_name(label, bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      abort_broker("#{label} invalid UTF-8") if !text.valid_encoding?
      text
    end

    # Trusted-local protocol: any framing inconsistency is a client bug, not a
    # recoverable runtime condition. Silently dropping it would hide the bug.
    # Process.exit! (not raise) because: this runs in the reader thread, and
    # process_submission has a broad `rescue => e` that would swallow a regular
    # exception. SystemExit raised from a non-main thread does not terminate
    # the process either. Process.exit! skips at-exit hooks but guarantees the
    # broker is gone regardless of which thread tripped the fault.
    def abort_broker(message)
      warn("urpc broker: #{message}")
      Process.exit!(1)
    end

    def broadcast_monitor_call(call)
      return if monitors.empty?
      formatted_args = call.args.map(&:inspect).join(", ")
      formatted_kargs = call.kargs.empty? ? nil : call.kargs.map { "#{it[0]}: #{it[1].inspect}" }.join(", ")
      all_args = [formatted_args, formatted_kargs].compact.reject(&:empty?).join(", ")
      type = call.cast? ? "CAST" : "CALL"
      line = "[#{'%.6f' % Time.now.to_f}] [#{call.id[0..7]}] #{type} #{call.rpc_key} ##{call.name}(#{all_args})\n"
      broadcast_monitor_line(line)
    end

    def broadcast_monitor_response(call_or_id, frame)
      return if monitors.empty?
      id = call_or_id.is_a?(String) ? call_or_id : call_or_id.id
      type, raw_payload = frame
      response_type = MONITOR_RESPONSE_TYPES.fetch(type)
      preview = monitor_payload_preview(raw_payload)
      line = "[#{'%.6f' % Time.now.to_f}] {#{id[0..7]}} #{response_type} #{preview}\n"
      broadcast_monitor_line(line)
    end

    def monitor_payload_preview(raw_payload)
      Frames.unpack_payload(raw_payload).inspect[0, MONITOR_PAYLOAD_PREVIEW_LENGTH]
    end

    def broadcast_monitor_line(line)
      return if monitors.empty?
      dead_socks = []
      state_lock.synchronize do
        monitors.each do |sock|
          begin
            sock.write_nonblock(line)
          rescue IO::WaitWritable, Errno::EAGAIN
            nil
          rescue Errno::EPIPE, Errno::ECONNRESET, IOError
            dead_socks << sock
          end
        end
        dead_socks.each do |sock|
          monitors.delete(sock)
          sock.close rescue nil
        end
      end
    end

    def process_submission(frame)
      received_at = monotonic_now
      id = frame[:id_hex]
      request_call =
        if frame[:inline]
          begin
            Call.load_body(
              id, frame[:body],
              rpc_key: frame[:rpc_key],
              name: frame[:method_name],
              cast: frame[:cast],
              wait_for_server: frame[:wait_for_server],
            )
          rescue MessagePack::UnpackError, Call::Invalid => e
            abort_broker("malformed inline submit body #{id}: #{e.class} #{e.message}")
          end
        else
          begin
            Call.load(
              id,
              rpc_key: frame[:rpc_key],
              name: frame[:method_name],
              cast: frame[:cast],
              wait_for_server: frame[:wait_for_server],
            )
          rescue Errno::ENOENT => e
            abort_broker("file-backed submit missing request file #{id}: #{e.message}")
          rescue MessagePack::UnpackError, Call::Invalid => e
            abort_broker("malformed file-backed submit body #{id}: #{e.class} #{e.message}")
          ensure
            File.unlink(Call.request_path(id)) rescue nil
          end
        end

      if !request_call.cast? && !File.pipe?(request_call.reply_path)
        warn("urpc broker: reply fifo missing or invalid for #{id}")
        return
      end

      call = BrokerCall.new(call: request_call, received_at:)

      broadcast_monitor_call(call)

      if !enqueue_submitted_call(call) && !call.cast?
        synthesize_call_error(call, Urpc::NoServerError, "no server registered for #{call.rpc_key}")
      end
    rescue => e
      warn("urpc broker: failed to process request #{id}: #{e.class} #{e.message}")
      if call
        synthesize_call_error(call, Urpc::RemoteException, "#{e.class}: #{e.message}")
      else
        synthesize_error_reply(id, Urpc::RemoteException, "#{e.class}: #{e.message}")
      end
    end

    def enqueue_submitted_call(call)
      state_lock.synchronize do
        has_backend = backend_count_locked(call.rpc_key) > 0
        can_enqueue = has_backend || call.wait_for_server?
        if can_enqueue
          start_wait_budget_if_needed_locked(call) if !has_backend
          enqueue_call_locked(call)
        end
        can_enqueue
      end
    end

    def start_wait_budget_if_needed_locked(call)
      return if call.wait_deadline
      return if !call.wait_for_server?
      seconds = call.wait_for_server_seconds
      return if !seconds

      call.wait_deadline = call.received_at + seconds
      track_wait_call_locked(call)
    end

    def enqueue_call_locked(call)
      active_ids[call.id] = call.rpc_key
      (queues_by_key[call.rpc_key] ||= Queue.new) << call
    end

    def track_wait_call_locked(call)
      wait_calls_by_id[call.id] = call
      return if next_wait_deadline && call.wait_deadline >= next_wait_deadline
      self.next_wait_deadline = call.wait_deadline
      wait_cv.broadcast
    end

    def untrack_wait_call_locked(call)
      return if !wait_calls_by_id.delete(call.id)
      return if !call.wait_deadline || call.wait_deadline != next_wait_deadline
      self.next_wait_deadline = nil
      wait_cv.broadcast
    end

    def claim_call_for_dispatch(call)
      expired_call = nil
      claimed = state_lock.synchronize do
        if !active_ids.key?(call.id)
          false
        elsif call.wait_deadline && call.wait_deadline <= monotonic_now
          untrack_wait_call_locked(call)
          active_ids.delete(call.id)
          expired_call = call
          false
        else
          untrack_wait_call_locked(call)
          true
        end
      end

      synthesize_wait_expired_calls([expired_call]) if expired_call
      claimed
    end

    def mark_call_dispatched(call)
      state_lock.synchronize do
        untrack_wait_call_locked(call)
      end
    end

    def synthesize_error_reply(id, exception_class, message)
      reply_path = Call.reply_path(id)
      return if !File.pipe?(reply_path)
      io = Util.open_reply_writer(reply_path)
      if !io
        File.unlink(reply_path) rescue nil
        return
      end
      begin
        write_error_frame(id, io, exception_class, message)
      ensure
        io.close rescue nil
        File.unlink(reply_path) rescue nil
      end
    end

    def synthesize_call_error(call, exception_class, message)
      return if call.cast?
      if !call.ensure_reply_open
        abandon_call(call)
        return
      end

      begin
        write_error_frame(call.id, call.reply_io, exception_class, message)
      ensure
        finish_call(call)
      end
    end

    def write_error_frame(id, io, exception_class, message)
      frame = Frames.error_frame(exception_class.new(message))
      broadcast_monitor_response(id, frame)
      io.write(MessagePack.pack(frame))
    rescue Errno::EPIPE
      nil
    end

    def accept_loop
      loop do
        client = sock_server.accept
        Thread.new { handshake(client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def handshake(sock)
      unpacker = MessagePack::DefaultFactory.unpacker(sock)
      timeout_thread = Thread.new do
        sleep(HANDSHAKE_DEADLINE)
        sock.close rescue nil
      end

      key = nil
      begin
        key = unpacker.read
      rescue IOError, MessagePack::UnpackError
        sock.close rescue nil
        return
      ensure
        timeout_thread.kill rescue nil
      end

      if !key.is_a?(String) || key.empty? || key == RESERVED_KEY
        sock.close rescue nil
        return
      end

      register_backend(key, sock, unpacker)
    rescue => e
      warn("urpc broker: handshake failed: #{e.class} #{e.message}")
      sock.close rescue nil
    end

    def register_backend(key, sock, unpacker)
      backend = Backend.new(key: key, sock: sock, unpacker: unpacker, broker: self)
      state_lock.synchronize do
        queues_by_key[key] ||= Queue.new
        (backends_by_key[key] ||= []) << backend
      end
      backend.start
    end

    def unregister_backend(backend)
      key = backend.key
      drained_calls = state_lock.synchronize do
        remove_backend_locked(backend)
        drain_queued_calls_if_no_backends_locked(key)
      end

      synthesize_no_server_for_drained_calls(key, drained_calls)
    end

    def backend_dispatch_failed(backend, call)
      key = backend.key
      expired_calls = []
      failed_calls = state_lock.synchronize do
        remove_backend_locked(backend)
        if call.wait_deadline && call.wait_deadline <= monotonic_now
          untrack_wait_call_locked(call)
          active_ids.delete(call.id)
          expired_calls << call
          []
        else
          track_wait_call_locked(call) if call.wait_deadline
          enqueue_call_locked(call)
          drain_queued_calls_if_no_backends_locked(key)
        end
      end

      synthesize_wait_expired_calls(expired_calls)
      synthesize_no_server_for_drained_calls(key, failed_calls)
    end

    def remove_backend_locked(backend)
      key = backend.key
      list = backends_by_key[key] || []
      list.delete(backend)
      backends_by_key.delete(key) if list.empty?
    end

    def drain_queued_calls_if_no_backends_locked(key)
      return [] if backend_count_locked(key) > 0

      q = queues_by_key.delete(key)
      failed_calls = []
      waiting_calls = []
      now = monotonic_now
      loop do
        begin
          call = q&.pop(true)
        rescue ThreadError
          break
        end
        break if !call

        start_wait_budget_if_needed_locked(call)

        if call.wait_deadline && call.wait_deadline <= now
          untrack_wait_call_locked(call)
          active_ids.delete(call.id)
          failed_calls << call
        elsif call.wait_for_server?
          waiting_calls << call
        else
          untrack_wait_call_locked(call)
          active_ids.delete(call.id)
          failed_calls << call
        end
      end

      if !waiting_calls.empty?
        waiting_q = Queue.new
        waiting_calls.each { waiting_q << it }
        queues_by_key[key] = waiting_q
      end

      failed_calls
    end

    def synthesize_no_server_for_drained_calls(key, calls)
      calls.each do |call|
        if !call.cast?
          if call.wait_deadline && call.wait_deadline <= monotonic_now
            synthesize_wait_expired_calls([call])
          else
            synthesize_call_error(call, Urpc::NoServerError, "no server registered for #{key}")
          end
        end
      end
    end

    def synthesize_wait_expired_calls(calls)
      calls.compact.each do |call|
        next if call.cast?
        seconds = call.wait_for_server_seconds
        message = if seconds
          "no server registered for #{call.rpc_key} after #{seconds}s"
        else
          "no server registered for #{call.rpc_key}"
        end
        synthesize_call_error(call, Urpc::NoServerError, message)
      end
    end

    def abandon_call(call)
      state_lock.synchronize do
        untrack_wait_call_locked(call)
        active_ids.delete(call.id)
      end
      call.abandon!
    end

    def finish_call(call)
      state_lock.synchronize do
        untrack_wait_call_locked(call)
        active_ids.delete(call.id)
      end
      call.finish!
    end
  end
end
