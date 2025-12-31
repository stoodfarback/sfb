# frozen_string_literal: true

require_relative("test_helper")

class TestCoreExtEnumerable < Minitest::Test
  def test_most_common_element
    assert_equal(2, [1, 2, 2, 3].most_common_element)
  end
end
