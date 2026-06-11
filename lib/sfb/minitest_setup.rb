# frozen_string_literal: true

# Minitest 6 moved Object#stub into minitest-mock. sfb keeps stub as part of
# the default Minitest environment because downstream personal projects use it
# without otherwise needing mocks.
#
# sfb/outside_gems registers Minitest as an autoload for this file. A later
# require("minitest") or require("minitest/autorun") opens the Minitest constant,
# which triggers this setup first. If Minitest was already loaded before sfb,
# outside_gems requires this file directly instead.

require("minitest")
require("minitest/mock")
