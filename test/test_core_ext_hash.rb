# frozen_string_literal: true

require_relative("test_helper")

class TestCoreExtHash < Minitest::Test
  def test_same_keys
    assert({}.same_keys?({}))
    assert({ a: 1 }.same_keys?({ a: 1 }))
    refute({ b: 1 }.same_keys?({ a: 1 }))
    refute({ a: 1 }.same_keys?({ a: 1, b: 2 }))
  end
end
