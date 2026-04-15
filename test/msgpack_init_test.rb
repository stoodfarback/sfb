# frozen_string_literal: true

require_relative("test_helper")
require("json")
require("open3")
require("rbconfig")

class MsgpackInitTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB_DIR = File.join(ROOT, "lib")

  def test_sfb_eagerly_loads_msgpack_and_installs_types
    data = run_ruby(<<~RUBY)
      require("json")
      require("sfb")
      require("date")

      module MsgpackInitAutoInstallAfterSfb
      end

      packed_missing = MessagePack.pack(MsgpackInitAutoInstallAfterSfb)
      Object.send(:remove_const, :MsgpackInitAutoInstallAfterSfb)

      values = MessagePack.unpack(MessagePack.pack([
        :ok,
        String,
        Date.parse("2024-01-02"),
        DateTime.parse("2024-01-02T03:04:05+00:00"),
        Time.rfc2822("Tue, 02 Jan 2024 03:04:05 +0000"),
      ]))
      missing = MessagePack.unpack(packed_missing)

      puts(JSON.generate(
        msgpack_loaded: $LOADED_FEATURES.any? { |feature| feature == "msgpack.rb" || feature.end_with?("/msgpack.rb") },
        symbol: [values[0].class.name, values[0].to_s],
        module_name: values[1].name,
        date: [values[2].class.name, values[2].iso8601],
        datetime: [values[3].class.name, values[3].iso8601],
        time: [values[4].class.name, values[4].rfc2822],
        missing: [missing.class.name, missing],
      ))
    RUBY

    assert_equal(true, data.fetch("msgpack_loaded"))
    assert_equal(%w[Symbol ok], data.fetch("symbol"))
    assert_equal("String", data.fetch("module_name"))
    assert_equal(%w[Date 2024-01-02], data.fetch("date"))
    assert_equal(["DateTime", "2024-01-02T03:04:05+00:00"], data.fetch("datetime"))
    assert_equal(["Time", "Tue, 02 Jan 2024 03:04:05 +0000"], data.fetch("time"))
    assert_equal(%w[String MsgpackInitAutoInstallAfterSfb], data.fetch("missing"))
  end

  def test_installs_when_msgpack_loads_before_sfb
    data = run_ruby(<<~RUBY)
      require("json")
      require("msgpack")

      before = MessagePack.unpack(MessagePack.pack(:ok))
      require("sfb")
      after = MessagePack.unpack(MessagePack.pack(:ok))

      puts(JSON.generate(
        before: [before.class.name, before],
        after: [after.class.name, after.to_s],
      ))
    RUBY

    assert_equal(%w[String ok], data.fetch("before"))
    assert_equal(%w[Symbol ok], data.fetch("after"))
  end

  def test_overwrites_existing_registration
    data = run_ruby(<<~RUBY)
      require("json")
      require("msgpack")

      MessagePack::DefaultFactory.register_type(
        0x00,
        Symbol,
        packer: ->(obj) { obj.to_s },
        unpacker: ->(data) { "custom:\#{data}" },
      )

      preserved = MessagePack.unpack(MessagePack.pack(:ok))
      require("sfb")

      after = MessagePack.unpack(MessagePack.pack(:ok))

      puts(JSON.generate(
        preserved: [preserved.class.name, preserved],
        after: [after.class.name, after.to_s],
      ))
    RUBY

    assert_equal(["String", "custom:ok"], data.fetch("preserved"))
    assert_equal(%w[Symbol ok], data.fetch("after"))
  end

  def test_backwards_compatible_with_previous_symbol_and_module_wire_formats
    data = run_ruby(<<~RUBY)
      require("json")
      require("base64")
      require("msgpack")

      module MsgpackInitCompatOuter
        module Inner
        end
      end

      MessagePack::DefaultFactory.register_type(0x00, Symbol)
      MessagePack::DefaultFactory.register_type(0x01, Module,
        packer: ->(klass) { klass.name },
        unpacker: ->(value) { Object.const_defined?(value) ? Object.const_get(value) : value },
      )

      packed_symbol_old = MessagePack.pack(:ok)
      packed_module_old = MessagePack.pack(MsgpackInitCompatOuter::Inner)

      require("sfb")

      packed_symbol_new = MessagePack.pack(:ok)
      packed_module_new = MessagePack.pack(MsgpackInitCompatOuter::Inner)

      symbol = MessagePack.unpack(packed_symbol_old)
      present = MessagePack.unpack(packed_module_old)

      Object.send(:remove_const, :MsgpackInitCompatOuter)
      missing = MessagePack.unpack(packed_module_old)

      puts(JSON.generate(
        packed_symbol_old: Base64.strict_encode64(packed_symbol_old),
        packed_symbol_new: Base64.strict_encode64(packed_symbol_new),
        packed_module_old: Base64.strict_encode64(packed_module_old),
        packed_module_new: Base64.strict_encode64(packed_module_new),
        symbol: [symbol.class.name, symbol.to_s],
        present: [present.class.name, present.name],
        missing: [missing.class.name, missing],
      ))
    RUBY

    assert_equal(data.fetch("packed_symbol_old"), data.fetch("packed_symbol_new"))
    assert_equal(data.fetch("packed_module_old"), data.fetch("packed_module_new"))
    assert_equal(%w[Symbol ok], data.fetch("symbol"))
    assert_equal(["Module", "MsgpackInitCompatOuter::Inner"], data.fetch("present"))
    assert_equal(["String", "MsgpackInitCompatOuter::Inner"], data.fetch("missing"))
  end

  def run_ruby(code)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-rbundler/setup",
      "-I#{LIB_DIR}",
      "-e",
      code,
      chdir: ROOT,
    )

    assert(
      status.success?,
      "ruby snippet failed (status #{status.exitstatus})\nstdout:\n#{stdout}\nstderr:\n#{stderr}",
    )

    JSON.parse(stdout)
  end
end
