# frozen_string_literal: true

require_relative("test_helper")

class UrpcKvFacadeTest < Minitest::Test
  TEST_ROOT_PREFIX = "sfb:test:urpc_kv:"
  RUN_PREFIX = "#{TEST_ROOT_PREFIX}#{SecureRandom.hex(8)}:".freeze

  class << self
    attr_accessor(:startup_checked, :startup_skip_reason, :service_available)
  end

  def self.ensure_service!(test)
    if startup_skip_reason
      test.skip(startup_skip_reason)
    end

    return if startup_checked

    self.startup_checked = true

    begin
      Urpc::Client.new(Sfb::UrpcKv::RPC_KEY, timeout: 1, wait_for_server: 1).ping
      Sfb::UrpcKv.delete_all_with_prefix(TEST_ROOT_PREFIX)
      self.service_available = true
    rescue => e
      self.startup_skip_reason = "urpc_kv service unavailable or setup failed: #{e.class}: #{e.message}"
      test.skip(startup_skip_reason)
    end
  end

  def self.cleanup_after_run
    return if !service_available

    Sfb::UrpcKv.delete_all_with_prefix(TEST_ROOT_PREFIX)
  end

  Minitest.after_run do
    UrpcKvFacadeTest.cleanup_after_run
  end

  def setup
    self.class.ensure_service!(self)
  end

  def kv
    Sfb::UrpcKv.with_prefix("#{RUN_PREFIX}#{name}:")
  end

  def root_key(key)
    "#{RUN_PREFIX}#{name}:root:#{key}"
  end

  def test_root_operations_round_trip_through_service
    key = root_key("basic")

    assert_equal([false, nil], Sfb::UrpcKv.read(key))
    assert_nil(Sfb::UrpcKv.get(key))
    assert_equal(false, Sfb::UrpcKv.exists?(key))

    value = { "ok" => true, "items" => [1, 2, 3] }
    assert_equal(value, Sfb::UrpcKv.set(key, value))
    assert_equal([true, value], Sfb::UrpcKv.read(key))
    assert_equal(value, Sfb::UrpcKv.get(key))
    assert_equal(true, Sfb::UrpcKv.exists?(key))

    assert_equal([true, value], Sfb::UrpcKv.delete(key))
    assert_equal([false, nil], Sfb::UrpcKv.read(key))
    assert_equal([false, nil], Sfb::UrpcKv.delete(key))
  end

  def test_fetch_preserves_nil_as_a_hit_and_supports_expiry
    scoped_kv = kv
    calls = 0

    assert_nil(scoped_kv.fetch("nil") { calls += 1; nil })
    assert_nil(scoped_kv.fetch("nil") { calls += 1; "unused" })
    assert_equal(1, calls)
    assert_equal([true, nil], scoped_kv.read("nil"))

    assert_equal("gone", scoped_kv.fetch("short", ex: 0) { "gone" })
    assert_equal([false, nil], scoped_kv.read("short"))
  end

  def test_expire_deletes_immediately_when_seconds_is_zero
    scoped_kv = kv

    scoped_kv.set("expiring", "value")
    assert_equal(true, scoped_kv.expire("expiring", 0))
    assert_equal([false, nil], scoped_kv.read("expiring"))
  end

  def test_delete_all_with_prefix_returns_count_and_respects_scope
    scoped_kv = kv

    scoped_kv.set("tmp:a", 1)
    scoped_kv.set("tmp:b", 2)
    scoped_kv.set("keep", 3)

    assert_equal(2, scoped_kv.delete_all_with_prefix("tmp:"))
    assert_equal([false, nil], scoped_kv.read("tmp:a"))
    assert_equal([false, nil], scoped_kv.read("tmp:b"))
    assert_equal([true, 3], scoped_kv.read("keep"))

    assert_equal(1, scoped_kv.delete_all)
    assert_equal([false, nil], scoped_kv.read("keep"))
  end

  def test_scope_is_exact_prefix_wrapper_over_root_api
    prefix = "#{RUN_PREFIX}#{name}:scope:"
    scoped_kv = Sfb::UrpcKv.with_prefix(prefix)

    assert_equal(prefix, scoped_kv.prefix)
    assert(scoped_kv.prefix.frozen?)
    assert(scoped_kv.frozen?)
    assert_equal("#<Sfb::UrpcKv::Scope prefix=#{prefix.inspect}>", scoped_kv.inspect)
    assert_equal("#{prefix}start", scoped_kv.full_key(:start))

    scoped_kv.set(:start, "value")
    assert_equal("value", Sfb::UrpcKv.get("#{prefix}start"))

    nested = scoped_kv.with_prefix("nested:")
    assert_equal("#{prefix}nested:", nested.prefix)
    nested.set("item", "nested-value")
    assert_equal("nested-value", Sfb::UrpcKv.get("#{prefix}nested:item"))
  end

  def test_key_wrapper_works_from_root_and_scope
    full_key = root_key("single")
    root_single = Sfb::UrpcKv.key(full_key)

    assert_equal(full_key, root_single.key)
    assert(root_single.key.frozen?)
    assert(root_single.frozen?)
    assert_equal("#<Sfb::UrpcKv::Key key=#{full_key.inspect}>", root_single.inspect)
    assert_equal([false, nil], root_single.read)
    assert_nil(root_single.get)
    assert_equal(false, root_single.exists?)

    assert_equal("value", root_single.set("value"))
    assert_equal([true, "value"], root_single.read)
    assert_equal("value", root_single.get)
    assert_equal(true, root_single.exists?)
    assert_equal("value", Sfb::UrpcKv.get(full_key))

    assert_equal(true, root_single.expire(0))
    assert_equal([false, nil], root_single.read)

    scoped_kv = kv
    scoped_single = scoped_kv.key(:slot)
    calls = 0

    assert_equal(scoped_kv.full_key(:slot), scoped_single.key)
    assert_equal("computed", scoped_single.fetch { calls += 1; "computed" })
    assert_equal("computed", scoped_single.fetch { calls += 1; "unused" })
    assert_equal(1, calls)
    assert_equal([true, "computed"], scoped_single.delete)
    assert_equal([false, nil], scoped_single.delete)
  end

  def test_prefix_and_key_values_use_to_s_except_nil_or_empty
    scoped_kv = Sfb::UrpcKv.with_prefix(:symbol_prefix)

    assert_equal("symbol_prefix", scoped_kv.prefix)
    assert_equal("symbol_prefixkey", scoped_kv.full_key(:key))

    assert_raises(ArgumentError) { Sfb::UrpcKv.get(nil) }
    assert_raises(ArgumentError) { Sfb::UrpcKv.get("") }
    assert_raises(ArgumentError) { Sfb::UrpcKv.delete_all_with_prefix(nil) }
    assert_raises(ArgumentError) { Sfb::UrpcKv.delete_all_with_prefix("") }
    assert_raises(ArgumentError) { Sfb::UrpcKv.with_prefix(nil) }
    assert_raises(ArgumentError) { Sfb::UrpcKv.with_prefix("") }
    assert_raises(ArgumentError) { Sfb::UrpcKv.key(nil) }
    assert_raises(ArgumentError) { Sfb::UrpcKv.key("") }
    assert_raises(ArgumentError) { scoped_kv.full_key(nil) }
    assert_raises(ArgumentError) { scoped_kv.full_key("") }
    assert_raises(ArgumentError) { scoped_kv.key(nil) }
    assert_raises(ArgumentError) { scoped_kv.key("") }
  end

  def test_fetch_requires_a_block
    assert_raises(ArgumentError) { Sfb::UrpcKv.fetch(root_key("missing")) }
    assert_raises(ArgumentError) { kv.fetch("missing") }
    assert_raises(ArgumentError) { Sfb::UrpcKv.key(root_key("missing")).fetch }
  end
end
