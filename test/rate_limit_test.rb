# frozen_string_literal: true

require_relative("test_helper")

class RateLimitTest < Minitest::Test
  RateLimit = Sfb::RateLimit
  RateLimit.def_limit(:one, 0.1..0.2)
  RateLimit.def_limit(:two, 0.1..0.2)

  def test_basic
    assert(RateLimit.one)
    refute(RateLimit.one)
    val = RateLimit.left_till_one
    assert(val > 0.0, "Expected > 0.0 but got #{val}")
    assert(val <= 0.2, "Expected <= 0.2 but got #{val}")

    assert(RateLimit.left_till_two < 0.01)
    assert(RateLimit.two)
    refute(RateLimit.two)

    RateLimit.sleep_till_next(:one, :two, quiet: true)
    assert(RateLimit.one || RateLimit.two)

    RateLimit.set_one(0.2)
    assert(RateLimit.left_till_one > 0.1)
    assert(RateLimit.left_till_one < 0.3)
  end
end
