# frozen_string_literal: true

require_relative("test_helper")

class TestUtil < Minitest::Test
  def test_including
    t = Module.new do
      include(Sfb::Util)
    end
    assert_equal("7o66805she887", t.xxhash64("aoeu"))
  end

  def test_xxhash64
    assert_equal("7o66805she887", Sfb::Util.xxhash64("aoeu"))
    assert_equal(8_942_116_968_796_201_223, Sfb::Util.xxhash64i("aoeu"))
  end

  def test_activerecord_pg_advisory_xact_lock
    # TODO:
  end

  def test_random
    assert(Sfb::Util.random.is_a?(String))
  end

  def test_random_string
    assert_equal("4wpwqn87q9zdp2pj17th6m44pm3fm685", Sfb::Util.random_string(prng: Random.new(111)))
    assert_equal("4wpwq", Sfb::Util.random_string(prng: Random.new(111), len: 5))
    assert_equal("4wpwq", Sfb::Util.random_string(prng: Random.new(111), len: 5, type: :base32))
    assert_equal("wpwqn", Sfb::Util.random_string(prng: Random.new(111), len: 5, type: :random_letters))
    assert_equal("zuuzo", Sfb::Util.random_string(prng: Random.new(111), len: 5, type: :pronounceable))
    assert_raises(Sfb::Error) { Sfb::Util.random_string(type: :bad) }
    assert_equal("4wpwqn87", Sfb::Util.random_string(prng: Random.new(111), len: 5..10))
    assert_equal("4wpwqn87q9zdp2p", Sfb::Util.random_string(prng: Random.new(111), len: [5, 10, 15]))
  end

  def test_http_get
    html = Sfb::Util.http_get("http://example.com")
    noko = Sfb::Util.noko(html)
    assert_equal("Example Domain", noko.at_css("h1").text)
  end

  def test_human_to_number
    assert_equal(100, Sfb::Util.human_to_number("100"))
    assert_equal(100_000, Sfb::Util.human_to_number("100 k"))
    assert_equal(100_000, Sfb::Util.human_to_number("100k"))
    assert_equal(100_000_000, Sfb::Util.human_to_number("100m"))
  end

  def test_human_size_to_bytes
    assert_equal(100, Sfb::Util.human_size_to_bytes("100"))
    assert_equal(102_400, Sfb::Util.human_size_to_bytes("100 kb"))
    assert_equal(102_400, Sfb::Util.human_size_to_bytes("100kb"))
    assert_equal(104_857_600, Sfb::Util.human_size_to_bytes("100 mib"))
  end

  def test_str_truncate
    assert_equal("aoeu", Sfb::Util.str_truncate("aoeu", 5))
    assert_equal("aoeui", Sfb::Util.str_truncate("aoeui", 5))
    assert_equal("ao...", Sfb::Util.str_truncate("aoeuid", 5))
    assert_equal("ao...", Sfb::Util.str_truncate("aoeuidh", 5))
  end

  def test_noko
    noko = Sfb::Util.noko("<p>Hey</p>")
    assert_equal("Hey", noko.text)
  end

  def test_redis
    key = "Sfb::Util test_redis"
    Sfb::Util.redis_delete(key)

    assert_nil(Sfb::Util.redis_get(key))
    assert_equal(false, Sfb::Util.redis_exists?(key))
    assert_equal(1, Sfb::Util.redis_set(key, 1))
    assert_equal(true, Sfb::Util.redis_exists?(key))
    assert_equal(1, Sfb::Util.redis_get(key))

    assert_nil(Sfb::Util.redis_set(key, nil))
    assert_nil(Sfb::Util.redis_get(key))
    assert_equal(true, Sfb::Util.redis_exists?(key))

    assert_nil(Sfb::Util.redis_fetch(key) { "one" })
    Sfb::Util.redis_delete(key)
    assert_equal("one", Sfb::Util.redis_fetch(key) { "one" })
    assert_equal("one", Sfb::Util.redis_fetch(key) { "one" })
  end

  def test_rails_helpers
    assert_equal("$1,234.57", Sfb::Util.rails_helpers.number_to_currency(1234.5678))
    assert_equal(Sfb::Util.rails_helpers.object_id, Sfb::Util.rails_helpers.object_id)

    # make sure i18n locale file is loaded
    assert_equal("over 51 years", Sfb::Util.rails_helpers.time_ago_in_words(11111111))
  end
end
