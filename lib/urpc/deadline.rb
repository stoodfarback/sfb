# frozen_string_literal: true

module Urpc
  class Deadline
    attr_accessor(:expires_at)

    def initialize(expires_at)
      self.expires_at = expires_at
    end

    def self.after(duration)
      new(monotonic_now + duration.to_f)
    end

    def self.validate_duration!(value, name:)
      if !value.is_a?(Numeric) || !value.real? || !value.to_f.finite? || value.negative?
        raise(ArgumentError, "invalid #{name}: #{value.inspect}")
      end
      value
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining
      expires_at - self.class.monotonic_now
    end
  end
end
