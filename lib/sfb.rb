# frozen_string_literal: true

require("sfb/version")
require("sfb/outside_gems")
require("sfb/core_ext")
require("sfb/util")
require("sfb/store")
require("sfb/memo")
require("sfb/kv")

module Sfb
  class Error < StandardError; end
end
