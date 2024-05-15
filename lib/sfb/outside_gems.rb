# frozen_string_literal: true

require("active_support/core_ext/object/try")
require("active_support/core_ext/object/blank")
require("active_support/core_ext/string/access")
require("active_support/core_ext/array/grouping")
require("active_support/core_ext/enumerable")
require("active_support/core_ext/string/inflections")
require("active_support/core_ext/array/wrap")
require("active_support/core_ext/string/starts_ends_with")
require("pry")
require("redis")

autoload(:JSON, "json")
autoload(:XXhash, "xxhash")
autoload(:SecureRandom, "securerandom")
module Base32; autoload :Crockford, 'base32/crockford'; end
autoload(:HTTP, "http")
autoload(:Nokogiri, "nokogiri")
