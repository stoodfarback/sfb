# frozen_string_literal: true

require("date")
require("time")
require("msgpack")

MessagePack::DefaultFactory.register_type(0x00, Symbol,
  packer: -> { it.to_s },
  unpacker: -> { it.to_sym },
)
MessagePack::DefaultFactory.register_type(0x01, Module,
  packer: -> { it.name || it.inspect },
  unpacker: ->(data) do
    if data.is_a?(String)
      Object.const_get(data)
    else
      data
    end
  rescue NameError
    data
  end,
)
MessagePack::DefaultFactory.register_type(0x02, DateTime,
  packer: -> { it.to_s },
  unpacker: -> { DateTime.parse(it) },
)
MessagePack::DefaultFactory.register_type(0x03, Date,
  packer: -> { it.to_s },
  unpacker: -> { Date.parse(it) },
)
MessagePack::DefaultFactory.register_type(0x04, Time,
  packer: -> { it.rfc2822 },
  unpacker: -> { Time.rfc2822(it) },
)
