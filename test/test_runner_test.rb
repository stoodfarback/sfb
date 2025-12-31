# frozen_string_literal: true

require_relative("test_helper")

class TestRunnerTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("fixture/dummy_project", __dir__)

  def run_fixture(*args)
    stdout, stderr, status = Open3.capture3(
      "bin/test", *args,
      chdir: FIXTURE_DIR
    )
    [stdout + stderr, status]
  end

  def test_all_tests_run
    output, status = run_fixture
    assert(status.success?)
    assert_match(/4 runs/, output)
    assert_match(/0 failures/, output)
  end

  def test_pattern_filter
    output, status = run_fixture("alpha")
    assert(status.success?)
    assert_match(/2 runs/, output)
    assert_match(/0 failures/, output)
  end

  def test_verbose_flag
    output, status = run_fixture("--verbose")
    assert(status.success?)
    assert_match(/AlphaTest#test_one/, output)
    assert_match(/BetaTest#test_first/, output)
  end

  def test_seed_flag
    output, status = run_fixture("--seed", "12345")
    assert(status.success?)
    assert_match(/--seed 12345/, output)
  end

  def test_list_flag
    output, status = run_fixture("--list")
    assert(status.success?)
    assert_match(/4 test\(s\)/, output)
    assert_match(/AlphaTest/, output)
    assert_match(/test_one/, output)
    refute_match(/runs/, output)
  end

  def test_pattern_with_verbose
    output, status = run_fixture("alpha", "--verbose")
    assert(status.success?)
    assert_match(/AlphaTest#test_one/, output)
    refute_match(/BetaTest/, output)
    assert_match(/2 runs/, output)
  end

  def test_no_match
    output, status = run_fixture("nonexistent")
    refute(status.success?)
    assert_match(/No tests matched/, output)
  end
end
