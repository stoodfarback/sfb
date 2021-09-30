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
  end
end
