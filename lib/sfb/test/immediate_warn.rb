# frozen_string_literal: true

module Sfb::Test::ImmediateWarn
  class << self
    def setup!
      require("minitest/test")
      Minitest::Test.include(self)
      nil
    end
  end

  def immediate_warn(*messages)
    io = respond_to?(:sfb_output_capture_orig_stderr) ? sfb_output_capture_orig_stderr : nil
    return(warn(*messages)) if !io

    if messages.empty?
      io.puts
    else
      messages.each { io.puts(it) }
    end

    io.flush if io.respond_to?(:flush)
    nil
  end
end
