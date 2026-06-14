# frozen_string_literal: true

require_relative("test_helper")

class TestOutputCaptureTest < Minitest::Test
  LIB_DIR = File.expand_path("../lib", __dir__)
  ROOT = File.expand_path("..", __dir__)

  def run_minitest_snippet(code, env: {})
    stdout, stderr, status = Open3.capture3(
      { "SFB_SKIP_OUTPUT_CAPTURE" => nil }.merge(env),
      RbConfig.ruby,
      "-rbundler/setup",
      "-I#{LIB_DIR}",
      "-rsfb",
      "-e",
      code,
      chdir: ROOT,
    )

    [stdout, stderr, status]
  end

  def combined_output(stdout, stderr)
    stdout + stderr
  end

  def test_passing_stdout_and_stderr_are_suppressed
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class PassingOutputCaptureChildTest < Minitest::Test
        def test_noisy_pass
          puts("passing stdout noise")
          warn("passing stderr noise")
          assert(true)
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    assert(status.success?, output)
    refute_includes(output, "passing stdout noise")
    refute_includes(output, "passing stderr noise")
  end

  def test_failing_tests_print_bracketed_captured_output_to_stderr
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class FailingOutputCaptureChildTest < Minitest::Test
        def test_noisy_failure
          puts("failure stdout noise")
          warn("failure stderr noise")
          flunk("boom")
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    assert_includes(stderr, "--- Captured output from FailingOutputCaptureChildTest#test_noisy_failure ---")
    assert_includes(stderr, "failure stdout noise")
    assert_includes(stderr, "failure stderr noise")
    assert_includes(stderr, "--- End captured output ---")
  end

  def test_silent_failing_test_omits_capture_brackets
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class SilentFailingOutputCaptureChildTest < Minitest::Test
        def test_silent_failure
          flunk("boom")
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    refute_includes(stderr, "--- Captured output from")
    refute_includes(stderr, "--- End captured output ---")
  end

  def test_stdout_and_stderr_share_ordered_capture_buffer
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class OrderedOutputCaptureChildTest < Minitest::Test
        def test_order
          puts("ordered one")
          $stderr.puts("ordered two")
          puts("ordered three")
          flunk("boom")
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    assert_match(/ordered one.*ordered two.*ordered three/m, stderr)
  end

  def test_class_level_opt_out_passes_output_through
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class ClassOptOutOutputCaptureChildTest < Minitest::Test
        skip_output_capture_for(self)

        def test_noisy_pass
          puts("class opt out stdout")
          warn("class opt out stderr")
          assert(true)
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    assert(status.success?, output)
    assert_includes(output, "class opt out stdout")
    assert_includes(output, "class opt out stderr")
  end

  def test_method_level_opt_out_passes_only_selected_method_output_through
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class MethodOptOutOutputCaptureChildTest < Minitest::Test
        skip_output_capture_for(:test_noisy_pass_through)

        def test_noisy_pass_through
          puts("method opt out stdout")
          assert(true)
        end

        def test_noisy_suppressed
          puts("method captured stdout")
          assert(true)
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    assert(status.success?, output)
    assert_includes(output, "method opt out stdout")
    refute_includes(output, "method captured stdout")
  end

  def test_env_var_disables_capture
    stdout, stderr, status = run_minitest_snippet(<<~RUBY, env: { "SFB_SKIP_OUTPUT_CAPTURE" => "1" })
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class EnvDisabledOutputCaptureChildTest < Minitest::Test
        def test_noisy_pass
          puts("env disabled stdout")
          warn("env disabled stderr")
          assert(true)
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    assert(status.success?, output)
    assert_includes(output, "env disabled stdout")
    assert_includes(output, "env disabled stderr")
  end

  def test_child_process_and_direct_fd_output_are_captured
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class FdOutputCaptureChildTest < Minitest::Test
        def test_fd_output
          fd_stdout = IO.for_fd(1, "w", autoclose: false)
          fd_stderr = IO.for_fd(2, "w", autoclose: false)
          fd_stdout.puts("direct fd stdout")
          fd_stderr.puts("direct fd stderr")
          fd_stdout.flush
          fd_stderr.flush

          system(RbConfig.ruby, "-e", "STDOUT.puts('child stdout'); STDERR.puts('child stderr')")
          flunk("boom")
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    assert_includes(stderr, "direct fd stdout")
    assert_includes(stderr, "direct fd stderr")
    assert_includes(stderr, "child stdout")
    assert_includes(stderr, "child stderr")
  end

  def test_libc_buffered_output_is_flushed_into_capture
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("fiddle")
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class NativeOutputCaptureChildTest < Minitest::Test
        def test_native_printf
          printf = Fiddle::Function.new(Fiddle::Handle::DEFAULT["printf"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
          printf.call("native printf buffered noise")
          flunk("boom")
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    assert_includes(stderr, "native printf buffered noise")
  end

  def test_teardown_failure_prints_body_and_teardown_output
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class TeardownFailureOutputCaptureChildTest < Minitest::Test
        def teardown
          puts("teardown stdout noise")
          flunk("teardown boom")
        end

        def test_body_passes
          puts("body stdout noise")
          assert(true)
        end
      end
    RUBY

    refute(status.success?, combined_output(stdout, stderr))
    assert_includes(stderr, "--- Captured output from TeardownFailureOutputCaptureChildTest#test_body_passes ---")
    assert_includes(stderr, "body stdout noise")
    assert_includes(stderr, "teardown stdout noise")
  end

  def test_skipped_tests_discard_output
    stdout, stderr, status = run_minitest_snippet(<<~RUBY)
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class SkippedOutputCaptureChildTest < Minitest::Test
        def test_skip
          puts("skip stdout noise")
          skip("not now")
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    assert(status.success?, output)
    refute_includes(output, "skip stdout noise")
  end

  def test_parallelized_tests_raise_clear_error
    stdout, stderr, status = run_minitest_snippet(<<~RUBY, env: { "MT_CPU" => "2" })
      require("minitest/autorun")
      Sfb::Test::OutputCapture.setup!

      class ParallelOutputCaptureChildTest < Minitest::Test
        parallelize_me!

        def test_parallel
          assert(true)
        end
      end
    RUBY

    output = combined_output(stdout, stderr)
    refute(status.success?, output)
    assert_includes(output, "Sfb::Test::OutputCapture is incompatible with Minitest thread-parallel tests")
  end
end
