# frozen_string_literal: true

module Urpc
  class Event
    attr_accessor(:type, :data)

    def initialize(raw_frame:)
      type, raw = raw_frame
      self.type = type
      self.data = Frames.unpack_payload(raw)
    end
  end
end
