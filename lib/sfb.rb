# frozen_string_literal: true

require("sfb/outside_gems")
require("sfb/core_ext")

module Sfb
  autoload(:Util, "sfb/util")
  autoload(:Store, "sfb/store")
  autoload(:Memo, "sfb/memo")
  autoload(:KV, "sfb/kv")
  autoload(:RateLimit, "sfb/rate_limit")
end
