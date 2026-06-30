# frozen_string_literal: true

require_relative("test_helper")

class WaitIndicatorTest < Minitest::Test
  def wait_for_indicator_delay
    sleep(Sfb::WaitIndicator::DELAY_SECONDS * 2)
  end

  def clear_line(width)
    " " * width + "\r"
  end

  def test_fast_finish_is_quiet
    out, err = capture_io do
      Sfb::WaitIndicator.new("fast").finish!
      wait_for_indicator_delay
    end

    assert_equal("", out)
    assert_equal("", err)
  end

  def test_finish_flashes_done_and_clears_visible_indicator
    out, err = capture_io do
      indicator = Sfb::WaitIndicator.new("grabbing exclusive lock")
      wait_for_indicator_delay
      indicator.finish!
    end

    pending_line = "  grabbing exclusive lock..."
    assert_equal("", out)
    assert_equal("#{pending_line}\r  done\r#{clear_line(pending_line.length)}", err)
  end

  def test_start_returns_block_value
    out, err = capture_io do
      assert_equal(:ok, Sfb::WaitIndicator.start("fast") { :ok })
      wait_for_indicator_delay
    end

    assert_equal("", out)
    assert_equal("", err)
  end

  def test_start_finishes_after_exception
    out, err = capture_io do
      error = assert_raises(RuntimeError) do
        Sfb::WaitIndicator.start("failing operation") do
          wait_for_indicator_delay
          raise("boom")
        end
      end
      assert_equal("boom", error.message)
    end

    pending_line = "  failing operation..."
    assert_equal("", out)
    assert_equal("#{pending_line}\r  done\r#{clear_line(pending_line.length)}", err)
  end

  def test_older_indicator_does_not_clear_newer_visible_indicator
    out, err = capture_io do
      older = Sfb::WaitIndicator.new("older")
      wait_for_indicator_delay
      newer = Sfb::WaitIndicator.new("newer")
      wait_for_indicator_delay

      older.finish!
      newer.finish!
    end

    pending_line = "  newer..."
    assert_equal("", out)
    assert_equal("  older...\r#{pending_line}\r  done\r#{clear_line(pending_line.length)}", err)
  end
end
