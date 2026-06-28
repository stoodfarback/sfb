# frozen_string_literal: true

require_relative("../lib/sfb")
require("minitest/autorun")

# see `unote sfb-test-snapshot` for notes on assert_snapshot
Sfb::Test::Snapshot.setup!

Sfb::Test::OutputCapture.setup!
