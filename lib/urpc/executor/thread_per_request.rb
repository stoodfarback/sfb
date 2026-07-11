# frozen_string_literal: true

module Urpc::Executor
  class ThreadPerRequest < Base
    def submit(_reservation, accepted)
      thread = Thread.new { execute(accepted) }
      thread.abort_on_exception = true
      nil
    end
  end
end
