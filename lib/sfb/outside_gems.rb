# frozen_string_literal: true

require("tmpdir")
require("json")

require("active_support/core_ext/object/try")
require("active_support/core_ext/object/blank")
require("active_support/core_ext/module/delegation")
require("active_support/core_ext/class/subclasses")
require("active_support/core_ext/enumerable")
require("active_support/core_ext/array/grouping")
require("active_support/core_ext/array/wrap")
require("active_support/core_ext/array/access")
require("active_support/core_ext/string/starts_ends_with")
require("active_support/core_ext/string/inflections")
require("active_support/core_ext/string/access")

module ActiveSupport
  autoload(:Duration, "active_support/duration")
end

autoload(:Base64, "base64")
autoload(:Redis, "redis")
autoload(:XXhash, "xxhash")
autoload(:SecureRandom, "securerandom")
module Base32; autoload(:Crockford, "base32/crockford"); end
autoload(:HTTP, "http")
autoload(:Nokogiri, "nokogiri")
autoload(:MessagePack, "msgpack")
autoload(:YAML, "yaml")
module YAML; autoload(:Store, "yaml/store"); end
autoload(:PStore, "pstore")
autoload(:Open3, "open3")
autoload(:Socket, "socket")
autoload(:UNIXSocket, "socket")
autoload(:UNIXServer, "socket")
