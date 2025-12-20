module Sfb
  class TestRunner
    def self.run(file_pattern: "test/**/*_test.rb")
      list_only = ARGV.delete("-l") || ARGV.delete("--list")
      patterns = ARGV.map(&:downcase)

      require "minitest"

      # Prevent autorun from installing at_exit hook if we're in list mode
      Minitest.class_variable_set(:@@installed_at_exit, true) if list_only

      # Load all test files, tracking which file defines each class
      test_files = Dir[file_pattern]
      class_to_file = {}
      test_files.each do |f|
        before = Minitest::Runnable.runnables.dup
        require File.expand_path(f)
        (Minitest::Runnable.runnables - before).each { |klass| class_to_file[klass] = f }
      end

      # Initialize Minitest so runnable_methods works
      Minitest.seed = Random.new_seed

      # Find all test classes and their test methods
      all_tests = []
      Minitest::Runnable.runnables.each do |klass|
        klass.runnable_methods.each do |method|
          all_tests << [klass, method, class_to_file[klass]]
        end
      end

      # Filter tests if patterns provided - match against file, class, or method
      if patterns.any?
        all_tests = all_tests.select do |klass, method, file|
          search_str = "#{file} #{klass}##{method}".downcase
          patterns.all? { |p| search_str.include?(p) }
        end
      end

      if all_tests.empty?
        puts("No tests matched: #{patterns.join(', ')}")
        exit(1)
      end

      # Group by class for display
      by_class = all_tests.group_by(&:first)

      if list_only
        puts("#{all_tests.size} test(s) in #{by_class.size} class(es):")
        by_class.each do |klass, tests|
          puts("  #{klass}")
          tests.each { |_, method, _| puts("    #{method}") }
        end
        puts
        exit(0)
      end

      # Remove unmatched test methods before autorun kicks in
      matched_methods_by_class = by_class.transform_values { |tests| tests.map { |_, method, _| method } }

      Minitest::Runnable.runnables.each do |klass|
        matched = matched_methods_by_class[klass] || []
        next if matched.empty?

        # Keep only matched methods by redefining runnable_methods
        klass.define_singleton_method(:runnable_methods) { matched }
      end

      # Remove classes with no matched tests
      Minitest::Runnable.runnables.reject! { |klass| !matched_methods_by_class.key?(klass) }
    end
  end
end
