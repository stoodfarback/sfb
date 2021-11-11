# frozen_string_literal: true

require_relative("test_helper")

class TestKV < Minitest::Test
  KV = Sfb::KV

  def test_basic
    assert_equal("Sfb::KV ", KV.redis_prefix)
    KV.delete("aoeu")
    assert_nil(KV.get("aoeu"))
    assert_equal(1, KV.set("aoeu", 1))
    assert_equal(1, KV.get("aoeu"))
    assert_equal(1, KV.fetch("aoeu") { "one" })
    assert_equal(1, KV.delete("aoeu"))
    assert_equal("one", KV.fetch("aoeu") { "one" })

    KV.set_redis_prefix(Sfb::Util.random + " ")
    assert_nil(KV.get("aoeu"))
    assert_equal("one", KV.fetch("aoeu") { "one" })
    assert_equal("one", KV.fetch("aoeu") { 2 })
  end

  def test_expire
    key = "dolphin"
    KV.delete(key)
    assert_nil(KV.get(key))
    KV.set(key, "one")
    assert_equal("one", KV.get(key))
    KV.expire(key, 2)
    assert_equal("one", KV.get(key))
    sleep(1)
    assert_equal("one", KV.get(key))
    sleep(1.5)
    assert_nil(KV.get(key))
  end

  def test_delete_all_with_prefix
    %w[foo:one foo:two bar:three].each { KV.delete(_1) }
    KV.set("foo:one", 1)
    KV.set("foo:two", 2)
    KV.set("bar:three", 3)
    assert_equal(1, KV.get("foo:one"))
    assert_equal(2, KV.get("foo:two"))
    assert_equal(3, KV.get("bar:three"))
    assert_equal(2, KV.delete_all_with_prefix("foo:"))
    assert_nil(KV.get("foo:one"))
    assert_nil(KV.get("foo:two"))
    assert_equal(3, KV.get("bar:three"))
  end

  def test_add_kv_methods
    c1 = Class.new do
      def self.name; "Class1"; end
    end
    KV.add_kv_methods(c1)
    obj1 = c1.new
    obj1.kv_delete("foo")
    assert_nil(obj1.kv_get("foo"))

    c2 = Class.new do
      def self.name; "Class2"; end
    end
    KV.add_kv_methods(c2)
    obj2 = c2.new
    obj2.kv_delete("foo")
    assert_nil(obj2.kv_get("foo"))

    assert_equal("one", obj1.kv_set("foo", "one"))
    assert_equal("one", obj1.kv_get("foo"))
    assert_equal("two", obj2.kv_set("foo", "two"))
    assert_equal("two", obj2.kv_get("foo"))
    assert_equal("one", obj1.kv_get("foo"))

    assert_equal("one", c1.kv_get("foo"))
    assert_equal("two", c2.kv_get("foo"))
  end

  def test_add_kv_methods_delete_all
    class_name = "Class#{Sfb::Util.random}"
    c = Class.new do
      define_singleton_method(:name) { class_name }
    end
    KV.add_kv_methods(c)
    obj = c.new
    set_values = -> do
      obj.kv_set("a:one", 1)
      obj.kv_set("b:two", 2)
      obj.kv_set("a:three", 3)
    end
    get_values = -> do
      %w[a:one b:two a:three].map { obj.kv_get(_1) }
    end
    set_values.()
    assert_equal([1, 2, 3], get_values.())
    obj.kv_delete_all_with_prefix("a:")
    assert_equal([nil, 2, nil], get_values.())
    obj.kv_delete_all
    assert_equal([nil, nil, nil], get_values.())

    set_values.()
    assert_equal([1, 2, 3], get_values.())
    c.kv_delete_all_with_prefix("b:")
    assert_equal([1, nil, 3], get_values.())
    c.kv_delete_all
    assert_equal([nil, nil, nil], get_values.())
  end
end
