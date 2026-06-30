# frozen_string_literal: true

# SPEC:
# WaitIndicator is a small CLI helper for waits that are usually instant but occasionally user-visible, such as blocking on a file lock.
#
# Public API:
# - Sfb::WaitIndicator.new(message) -> indicator
# - indicator.finish! -> nil
# - Sfb::WaitIndicator.start(message) { ... } -> block return value
#
# Behavior:
# - Output goes to stderr.
# - If finished before DELAY_SECONDS, it prints nothing.
# - If still pending after DELAY_SECONDS, it prints:
#   "  #{message}...\r"
# - finish! is idempotent.
# - If this indicator is still the visible indicator, finish! writes a zero-dwell completion frame:
#   "  done\r"
#   then clears the full visible line with spaces and returns carriage.
#   The done frame is meant to preserve an ordered completion marker in captured/non-TTY output, so the final line does not
#   misleadingly look stuck on the pending lock message when no more output follows. Terminal cleanup still stays immediate,
#   so this is not meant to pause long enough for a human-visible done state.
# - start wraps the block with ensure so visible indicators are cleared on exceptions.
# - Overlap is intentionally simple: the newest visible indicator owns the shared CLI line, and older indicators do not clear newer output.

module Sfb
  class WaitIndicator
    DELAY_SECONDS = 0.1
    PREFIX = "  "
    PENDING_SUFFIX = "..."
    DONE_MESSAGE = "done"

    class << self
      attr_accessor(:output_mutex, :visible_indicator, :visible_width)
    end

    self.output_mutex = Mutex.new
    self.visible_width = 0

    attr_accessor(:message, :mutex, :condition, :finished, :visible)

    def self.start(message)
      indicator = new(message)
      if !block_given?
        return(indicator)
      end

      begin
        yield
      ensure
        indicator.finish!
      end
    end

    def initialize(message)
      self.message = message
      self.mutex = Mutex.new
      self.condition = ConditionVariable.new
      self.finished = false
      self.visible = false

      Thread.new { delayed_show }
    end

    def finish!
      should_finish = false

      mutex.synchronize do
        if finished
          return
        end

        self.finished = true
        condition.broadcast
        should_finish = visible
      end

      if should_finish
        self.class.finish(self)
      end

      nil
    end

    def delayed_show
      should_show = false
      deadline = monotonic_now + DELAY_SECONDS

      mutex.synchronize do
        while !finished
          remaining = deadline - monotonic_now
          break if remaining <= 0

          condition.wait(mutex, remaining)
        end

        if !finished
          self.visible = true
          should_show = true
        end
      end

      if should_show
        self.class.show(self)
      end

      nil
    end

    def pending_line
      "#{PREFIX}#{message}#{PENDING_SUFFIX}"
    end

    def self.show(indicator)
      line = indicator.pending_line

      output_mutex.synchronize do
        indicator.mutex.synchronize do
          if indicator.finished
            return
          end
        end

        clear_width = (visible_width - line.length).clamp(0..)

        $stderr.write(line)
        $stderr.write(" " * clear_width)
        $stderr.write("\r")
        $stderr.flush

        self.visible_indicator = indicator
        self.visible_width = line.length
      end

      nil
    end

    def self.finish(indicator)
      output_mutex.synchronize do
        if visible_indicator != indicator
          return
        end

        done_line = "#{PREFIX}#{DONE_MESSAGE}"
        clear_width = visible_width.clamp(done_line.length..)

        $stderr.write("#{done_line}\r")
        $stderr.flush
        $stderr.write(" " * clear_width)
        $stderr.write("\r")
        $stderr.flush

        self.visible_indicator = nil
        self.visible_width = 0
      end

      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
