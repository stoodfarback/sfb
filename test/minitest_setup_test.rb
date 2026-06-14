# frozen_string_literal: true

require_relative("test_helper")

class MinitestSetupTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB_DIR = File.join(ROOT, "lib")

  def test_require_minitest_after_sfb_includes_stub
    data = run_ruby(<<~RUBY)
      require("sfb")
      require("minitest")

      puts(JSON.generate(
        test_loaded: defined?(Minitest::Test) == "constant",
        stub_available: Object.method_defined?(:stub),
      ))
    RUBY

    assert_equal(true, data.fetch("test_loaded"))
    assert_equal(true, data.fetch("stub_available"))
  end

  def test_require_minitest_autorun_after_sfb_includes_stub
    data = run_ruby(<<~RUBY)
      require("sfb")
      require("minitest/autorun")

      puts(JSON.generate(
        test_loaded: defined?(Minitest::Test) == "constant",
        stub_available: Object.method_defined?(:stub),
      ))
      STDOUT.flush
      exit!(0)
    RUBY

    assert_equal(true, data.fetch("test_loaded"))
    assert_equal(true, data.fetch("stub_available"))
  end

  def test_require_sfb_after_minitest_includes_stub
    data = run_ruby(<<~RUBY)
      require("minitest")
      before = Object.method_defined?(:stub)

      require("sfb")

      puts(JSON.generate(
        before: before,
        after: Object.method_defined?(:stub),
      ))
    RUBY

    assert_equal(false, data.fetch("before"))
    assert_equal(true, data.fetch("after"))
  end

  def run_ruby(code)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-rbundler/setup",
      "-I#{LIB_DIR}",
      "-e",
      code,
      chdir: ROOT,
    )

    assert(
      status.success?,
      "ruby snippet failed (status #{status.exitstatus})\nstdout:\n#{stdout}\nstderr:\n#{stderr}",
    )

    JSON.parse(stdout)
  end
end
