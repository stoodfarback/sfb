# frozen_string_literal: true

# Minitest stdout/stderr capture helper.
#
# Setup:
#   Sfb::Test::OutputCapture.setup!
#
# Passing and skipped tests discard captured output. Failing tests dump the
# captured stdout/stderr block after stdout/stderr have been restored.
#
# This redirects process-level file descriptors, so it is incompatible with
# Minitest's thread-parallel executor.

module Sfb::Test::OutputCapture
  module ClassMethods
    attr_accessor(:sfb_output_capture_disabled, :sfb_output_capture_skip_methods)

    def skip_output_capture_for(*args)
      raise(ArgumentError, "skip_output_capture_for requires at least one argument") if args.empty?

      if args.include?(self)
        raise(ArgumentError, "skip_output_capture_for(self) must be called alone, not mixed with method names") if args.length > 1

        self.sfb_output_capture_disabled = true
        return
      end

      args.each do |arg|
        raise(ArgumentError, "skip_output_capture_for expects symbols or strings, got #{arg.inspect}") if !arg.is_a?(Symbol) && !arg.is_a?(String)
      end

      self.sfb_output_capture_skip_methods ||= []
      sfb_output_capture_skip_methods.concat(args.map(&:to_s))
      nil
    end
  end

  class << self
    extend(Sfb::Memo)

    def setup!
      require("minitest/test")
      Sfb::Test::ImmediateWarn.setup!
      Minitest::Test.include(self)
      Minitest::Test.extend(ClassMethods)
      nil
    end

    def disabled_globally?
      ENV["SFB_SKIP_OUTPUT_CAPTURE"] == "1"
    end

    memo def fflush
      require("fiddle")
      Fiddle::Function.new(Fiddle::Handle::DEFAULT["fflush"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    end

    def fflush_all
      fflush.call(0)
      nil
    end
  end

  attr_accessor(
    :sfb_output_capture_buffer,
    :sfb_output_capture_orig_stderr,
    :sfb_output_capture_orig_stdout,
    :sfb_output_capture_reader,
    :sfb_output_capture_reader_thread,
    :sfb_output_capture_stderr_sync,
    :sfb_output_capture_stdout_sync,
    :sfb_output_capture_writer,
  )

  def before_setup
    super
    return if sfb_output_capture_disabled?

    sfb_output_capture_check_parallel!
    sfb_output_capture_start
    nil
  end

  def after_teardown
    after_teardown_failed = false

    begin
      super
    rescue Minitest::Assertion, StandardError
      after_teardown_failed = true
      raise
    ensure
      sfb_output_capture_finish(dump: after_teardown_failed)
    end
  end

  def sfb_output_capture_disabled?
    Sfb::Test::OutputCapture.disabled_globally? ||
      self.class.sfb_output_capture_disabled ||
      Array(self.class.sfb_output_capture_skip_methods).include?(name)
  end

  def sfb_output_capture_check_parallel!
    return if self.class.run_order != :parallel

    raise("Sfb::Test::OutputCapture is incompatible with Minitest thread-parallel tests: #{self.class}")
  end

  def sfb_output_capture_start
    self.sfb_output_capture_stdout_sync = $stdout.sync
    self.sfb_output_capture_stderr_sync = $stderr.sync
    self.sfb_output_capture_orig_stdout = $stdout.dup
    self.sfb_output_capture_orig_stderr = $stderr.dup

    reader, writer = IO.pipe
    writer.sync = true
    self.sfb_output_capture_reader = reader
    self.sfb_output_capture_writer = writer
    self.sfb_output_capture_buffer = +""
    self.sfb_output_capture_reader_thread = Thread.new do
      begin
        self.sfb_output_capture_buffer = reader.read.to_s
      ensure
        reader.close if !reader.closed?
      end
    end

    $stdout.reopen(writer)
    $stderr.reopen(writer)
    $stdout.sync = true
    $stderr.sync = true
    nil
  rescue
    sfb_output_capture_restore_original_streams
    sfb_output_capture_close_writer
    sfb_output_capture_join_reader
    sfb_output_capture_close_reader
    sfb_output_capture_close_original_streams
    sfb_output_capture_clear
    raise
  end

  def sfb_output_capture_finish(dump: false)
    return if sfb_output_capture_writer.nil?

    begin
      Sfb::Test::OutputCapture.fflush_all
    ensure
      sfb_output_capture_restore_original_streams
      sfb_output_capture_close_writer
      sfb_output_capture_join_reader
      sfb_output_capture_close_reader
      sfb_output_capture_close_original_streams
      sfb_output_capture_dump(sfb_output_capture_buffer.to_s) if dump || (!passed? && !skipped?)
      sfb_output_capture_clear
    end

    nil
  end

  def sfb_output_capture_restore_original_streams
    if sfb_output_capture_orig_stdout
      $stdout.reopen(sfb_output_capture_orig_stdout)
      $stdout.sync = sfb_output_capture_stdout_sync
    end

    if sfb_output_capture_orig_stderr
      $stderr.reopen(sfb_output_capture_orig_stderr)
      $stderr.sync = sfb_output_capture_stderr_sync
    end

    nil
  end

  def sfb_output_capture_close_writer
    writer = sfb_output_capture_writer
    writer.close if writer && !writer.closed?
    nil
  end

  def sfb_output_capture_join_reader
    thread = sfb_output_capture_reader_thread
    thread.join if thread
    nil
  end

  def sfb_output_capture_close_reader
    reader = sfb_output_capture_reader
    reader.close if reader && !reader.closed?
    nil
  end

  def sfb_output_capture_close_original_streams
    [sfb_output_capture_orig_stdout, sfb_output_capture_orig_stderr].each do |io|
      next if io.nil?
      next if io.closed?

      io.close
    end
    nil
  end

  def sfb_output_capture_dump(buffer)
    printable = buffer.dup
    printable.force_encoding(Encoding::UTF_8)
    printable = printable.scrub("?")
    return if printable.empty?

    $stderr.puts("--- Captured output from #{self.class}##{name} ---")
    $stderr.write(printable)
    $stderr.puts if !printable.end_with?("\n")
    $stderr.puts("--- End captured output ---")
    nil
  end

  def sfb_output_capture_clear
    self.sfb_output_capture_buffer = nil
    self.sfb_output_capture_orig_stderr = nil
    self.sfb_output_capture_orig_stdout = nil
    self.sfb_output_capture_reader = nil
    self.sfb_output_capture_reader_thread = nil
    self.sfb_output_capture_stderr_sync = nil
    self.sfb_output_capture_stdout_sync = nil
    self.sfb_output_capture_writer = nil
    nil
  end
end
