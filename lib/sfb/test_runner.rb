# frozen_string_literal: true

module Sfb
  class TestRunner
    def self.run(file_pattern: "test/**/*_test.rb")
      list_only = ARGV.delete("-l") || ARGV.delete("--list")
      match_any = ARGV.delete("--match-any")

      # Separate minitest options from filter patterns
      minitest_args = []
      patterns = []
      i = 0
      while i < ARGV.size
        arg = ARGV[i]
        if arg.start_with?("-")
          minitest_args << arg
          # Capture option value if present
          if i + 1 < ARGV.size && !ARGV[i + 1].start_with?("-")
            i += 1
            minitest_args << ARGV[i]
          end
        else
          patterns << arg.downcase
        end
        i += 1
      end

      require("minitest")

      # Prevent autorun from installing at_exit hook if we're in list mode
      Minitest.class_variable_set(:@@installed_at_exit, true) if list_only

      # Load all test files, tracking which file defines each class
      test_files = Dir[file_pattern]
      class_to_file = {}
      test_files.each do |f|
        before = Minitest::Runnable.runnables.dup
        require(File.expand_path(f))
        (Minitest::Runnable.runnables - before).each {|klass| class_to_file[klass] = f }
      end

      # Initialize Minitest so runnable_methods works
      Minitest.seed = Random.new_seed

      # Find all test classes and their test methods
      available_tests = []
      Minitest::Runnable.runnables.each do |klass|
        klass.runnable_methods.each do |method|
          available_tests << [klass, method, class_to_file[klass]]
        end
      end
      available_tests.sort_by! {|klass, method, file| [file.to_s, klass.to_s, method.to_s] }

      # Filter tests if patterns provided - match against file, class, or method
      all_tests = if patterns.any?
        available_tests.select do |klass, method, file|
          search_str = "#{file} #{klass}##{method}".downcase
          if match_any
            patterns.any? {|p| search_str.include?(p) }
          else
            patterns.all? {|p| search_str.include?(p) }
          end
        end
      else
        available_tests
      end

      if all_tests.empty?
        puts("No tests matched: #{patterns.join(", ")}")
        puts
        if patterns.size > 1 && !match_any
          puts("Tip: Consider using --match-any to switch from AND to OR matching")
          puts
        end
        if available_tests.any?
          puts("Available tests (first 3):")
          available_tests.first(3).each do |klass, method, file|
            puts("  #{file} #{klass}##{method}")
          end
          puts
        end
        puts("Usage: bin/test [options] [pattern ...]")
        puts("  Patterns filter by file path, class name, or method name (case-insensitive)")
        puts("  Multiple patterns use AND logic (all must match)")
        puts("  --match-any  Switch to OR logic for multiple patterns")
        puts("  -l, --list  List matching tests without running them")
        puts
        puts("Examples:")
        puts("  bin/test session       # run tests with 'session' in file/class/method")
        puts("  bin/test session basic # run tests matching both 'session' AND 'basic'")
        puts("  bin/test --match-any test/util_test.rb test/kv_test.rb # run tests in either file")
        puts("  bin/test -l            # list all tests")
        exit(1)
      end

      # Group by class for display
      by_class = all_tests.group_by(&:first)

      if list_only
        puts("#{all_tests.size} test(s) in #{by_class.size} class(es):")
        by_class.each do |klass, tests|
          puts("  #{klass}")
          tests.each {|_, method, _| puts("    #{method}") }
        end
        puts
        exit(0)
      end

      # Remove unmatched test methods before autorun kicks in
      matched_methods_by_class = by_class.transform_values {|tests| tests.map {|_, method, _| method } }

      Minitest::Runnable.runnables.each do |klass|
        matched = matched_methods_by_class[klass] || []
        next if matched.empty?

        # Keep only matched methods by redefining runnable_methods
        klass.define_singleton_method(:runnable_methods) { matched }
      end

      # Remove classes with no matched tests
      Minitest::Runnable.runnables.reject! {|klass| !matched_methods_by_class.key?(klass) }

      # Pass minitest args through for autorun to process
      ARGV.replace(minitest_args)
    end
  end
end
