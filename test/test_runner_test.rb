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
    assert_match(/No tests matched: nonexistent/, output)
    assert_match(/Available tests \(first 3\):/, output)
    assert_match(/test\/alpha_test\.rb AlphaTest#test_two/, output)
    assert_match(/Usage: bin\/test/, output)
  end

  def test_no_match_multiple_patterns_tip
    output, status = run_fixture("alpha", "beta")
    refute(status.success?)
    assert_match(/Tip: Consider using --match-any to switch from AND to OR matching/, output)
  end

  def test_match_any
    # 'alpha' matches 2 tests, 'beta' matches 2 tests. Total 4.
    output, status = run_fixture("--match-any", "alpha", "beta")
    assert(status.success?)
    assert_match(/4 runs/, output)
  end

  def test_match_any_list
    output, status = run_fixture("--match-any", "--list", "alpha", "beta")
    assert(status.success?)
    assert_match(/4 test\(s\)/, output)
  end
end
