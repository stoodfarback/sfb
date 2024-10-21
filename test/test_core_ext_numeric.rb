# frozen_string_literal: true

require_relative("test_helper")

class TestCoreExtNumeric < Minitest::Test
  def test_time
    assert_equal(1, 1.second.to_i)
    assert_equal(2, 2.seconds.to_i)
    assert_equal(60 * 1, 1.minute.to_i)
    assert_equal(60 * 2, 2.minutes.to_i)
    assert_equal(60 * 60 * 1, 1.hour.to_i)
    assert_equal(60 * 60 * 2, 2.hours.to_i)
    assert_equal(24 * 60 * 60 * 1, 1.day.to_i)
    assert_equal(24 * 60 * 60 * 2, 2.days.to_i)

    # length of a gregorian year (365.2425 days)
    year = (365.2425 * 24 * 60 * 60).round
    # 1/12 of a gregorian year
    month = (year / 12.0).round

    assert_equal(month * 1, 1.month.to_i)
    assert_equal(month * 2, 2.months.to_i)
    assert_equal(year * 1, 1.year.to_i)
    assert_equal(year * 2, 2.years.to_i)
  end
end
