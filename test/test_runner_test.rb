# frozen_string_literal: true

require_relative("test_helper")

class TestRunnerTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("fixture/dummy_project", __dir__)

  def run_fixture(*)
    stdout, stderr, status = Open3.capture3(
      "bin/test", *,
      chdir: FIXTURE_DIR
    )
    [stdout + stderr, status]
  end

  def assert_snapshot_clean(output)
    cleaned = output.
      gsub(/--seed \d+/, "--seed <SEED>").
      gsub(/Finished in \d+\.\d+s/, "Finished in <TIME>s").
      gsub(%r{[\d.]+ runs/s, [\d.]+ assertions/s}, "<RATE> runs/s, <RATE> assertions/s").
      gsub(/= \d+\.\d+ s =/, "= <TIME> s =")
    assert_snapshot(cleaned)
  end

  def test_all_tests_run
    output, status = run_fixture
    assert(status.success?)
    assert_match(/4 runs/, output)
    assert_match(/0 failures/, output)
    assert_snapshot_clean(output)
  end

  def test_pattern_filter
    output, status = run_fixture("alpha")
    assert(status.success?)
    assert_match(/2 runs/, output)
    assert_match(/0 failures/, output)
    assert_snapshot_clean(output)
  end

  def test_verbose_flag
    output, status = run_fixture("--verbose", "--seed", "1")
    assert(status.success?)
    assert_match(/AlphaTest#test_one/, output)
    assert_match(/BetaTest#test_first/, output)
    assert_snapshot_clean(output)
  end

  def test_seed_flag
    output, status = run_fixture("--seed", "12345")
    assert(status.success?)
    assert_match(/--seed 12345/, output)
    assert_snapshot_clean(output)
  end

  def test_list_flag
    output, status = run_fixture("--list")
    assert(status.success?)
    assert_match(/4 test\(s\)/, output)
    assert_match(/AlphaTest/, output)
    assert_match(/test_one/, output)
    refute_match(/runs/, output)
    assert_snapshot_clean(output)
  end

  def test_pattern_with_verbose
    output, status = run_fixture("alpha", "--verbose", "--seed", "1")
    assert(status.success?)
    assert_match(/AlphaTest#test_one/, output)
    refute_match(/BetaTest/, output)
    assert_match(/2 runs/, output)
    assert_snapshot_clean(output)
  end

  def test_no_match
    output, status = run_fixture("nonexistent")
    refute(status.success?)
    assert_match(/No tests matched: nonexistent/, output)
    assert_match(/Available tests \(first 3\):/, output)
    assert_match(%r{test/alpha_test\.rb AlphaTest#test_two}, output)
    assert_match(%r{Usage: bin/test}, output)
    assert_snapshot_clean(output)
  end

  def test_no_tests_in_project
    stdout, stderr, status = Open3.capture3(
      "bundle", "exec", "ruby", "-Ilib", "-rsfb", "-e",
      'Sfb::TestRunner.run(file_pattern: "test/fixture/empty_dir/*_test.rb")',
    )
    output = stdout + stderr
    refute(status.success?)
    assert_match(%r{No tests found in test/fixture/empty_dir/\*_test\.rb}, output)
    refute_match(/No tests matched/, output)
    refute_match(%r{Usage: bin/test}, output)
    assert_snapshot_clean(output)
  end

  def test_multiple_patterns_default_or
    # 'alpha' matches 2 tests, 'beta' matches 2 tests. Total 4.
    output, status = run_fixture("alpha", "beta")
    assert(status.success?)
    assert_match(/4 runs/, output)
    assert_snapshot_clean(output)
  end

  def test_match_all
    # 'alpha' AND 'one' should match only AlphaTest#test_one
    output, status = run_fixture("--match-all", "alpha", "one")
    assert(status.success?)
    assert_match(/1 runs/, output)
    assert_snapshot_clean(output)
  end

  def test_match_all_list
    output, status = run_fixture("--match-all", "--list", "alpha", "one")
    assert(status.success?)
    assert_match(/1 test\(s\)/, output)
    assert_snapshot_clean(output)
  end
end
