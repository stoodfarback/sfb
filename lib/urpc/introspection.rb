# frozen_string_literal: true

module Urpc
  class Introspection
    attr_accessor(:broker)

    def initialize(broker)
      self.broker = broker
    end

    Util.def_stream_to_basic(self, :stats) { broker.stats_snapshot }
  end
end
