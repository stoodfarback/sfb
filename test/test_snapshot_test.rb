# frozen_string_literal: true

require_relative("test_helper")
require("stringio")

class TestSnapshotTest < Minitest::Test
  def with_sandbox
    Dir.mktmpdir("sfb_snapshot_test_") do |dir|
      @sandbox = Pathname(dir)
      prev_fixtures_dir = Sfb::Test::Snapshot.fixtures_dir
      prev_gsubs = Sfb::Test::Snapshot.gsubs
      Sfb::Test::Snapshot.gsubs = []
      Sfb::Test::Snapshot.fixtures_dir = @sandbox.to_s
      begin
        yield
      ensure
        Sfb::Test::Snapshot.fixtures_dir = prev_fixtures_dir
        Sfb::Test::Snapshot.gsubs = prev_gsubs
        ENV.delete("SFB_SNAPSHOT_STRICT")
      end
    end
  end

  def fixture_path_for(key, ext)
    File.join(@sandbox.to_s, "#{key}#{ext}")
  end

  def silence_warn(&)
    orig = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = orig
  end

  def test_string_fixture_created_on_first_run
    with_sandbox do
      path = fixture_path_for("test_snapshot/string_fixture_created_on_first_run", ".txt")
      refute(File.exist?(path))

      silence_warn { assert_snapshot("hello world") }

      assert(File.exist?(path))
      assert_equal("hello world", File.read(path))
    end
  end

  def test_string_fixture_match_passes_silently
    with_sandbox do
      path = fixture_path_for("test_snapshot/string_fixture_match_passes_silently", ".txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "stable")

      assert_snapshot("stable")

      assert_equal("stable", File.read(path))
    end
  end

  def test_string_fixture_mismatch_overwrites_and_warns
    with_sandbox do
      path = fixture_path_for("test_snapshot/string_fixture_mismatch_overwrites_and_warns", ".txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "old")

      captured_stderr = StringIO.new
      orig = $stderr
      $stderr = captured_stderr
      begin
        assert_snapshot("new")
      ensure
        $stderr = orig
      end

      assert_equal("new", File.read(path))
      assert_match(/Snapshot changed/, captured_stderr.string)
    end
  end

  def test_strict_mode_flunks_on_mismatch
    with_sandbox do
      path = fixture_path_for("test_snapshot/strict_mode_flunks_on_mismatch", ".txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "old")

      ENV["SFB_SNAPSHOT_STRICT"] = "1"
      assert_raises(Minitest::Assertion) do
        assert_snapshot("new")
      end
      assert_equal("old", File.read(path))
    end
  end

  def test_hash_fixture_uses_yaml
    with_sandbox do
      path = fixture_path_for("test_snapshot/hash_fixture_uses_yaml", ".yml")
      silence_warn { assert_snapshot({a: 1, b: "two"}) }

      assert(File.exist?(path))
      loaded = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      assert_equal({a: 1, b: "two"}, loaded)
    end
  end

  def test_normalize_strips_trailing_whitespace_and_outer_blank_lines
    with_sandbox do
      path = fixture_path_for("test_snapshot/normalize_strips_trailing_whitespace_and_outer_blank_lines", ".txt")
      silence_warn { assert_snapshot("\n\n  hello   \nworld  \n\n") }

      assert_equal("  hello\nworld", File.read(path))
    end
  end

  def test_gsubs_are_applied_before_comparison
    with_sandbox do
      Sfb::Test::Snapshot.gsubs << [/\d{4}-\d{2}-\d{2}/, "GSUB_DATE"]
      path = fixture_path_for("test_snapshot/gsubs_are_applied_before_comparison", ".txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "today is GSUB_DATE")

      assert_snapshot("today is 2026-04-15")
      assert_equal("today is GSUB_DATE", File.read(path))
    end
  end

  def test_gsubs_also_apply_inside_structures
    with_sandbox do
      Sfb::Test::Snapshot.gsubs << [/\d{4}-\d{2}-\d{2}/, "GSUB_DATE"]
      path = fixture_path_for("test_snapshot/gsubs_also_apply_inside_structures", ".yml")

      silence_warn { assert_snapshot({date: "2026-04-15", other: 42}) }

      loaded = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      assert_equal({date: "GSUB_DATE", other: 42}, loaded)
    end
  end

  def test_setup_deep_dups_common_gsubs
    with_sandbox do
      Sfb::Test::Snapshot.setup!(dir: @sandbox.to_s)

      Sfb::Test::Snapshot.gsubs.first[1] = "CHANGED"

      assert_equal("GSUB_TIMESTAMP_TZ", Sfb::Test::Snapshot::COMMON_GSUBS.first[1])
    end
  end

  def test_duplicate_implicit_name_raises
    with_sandbox do
      silence_warn { assert_snapshot("first") }
      err = assert_raises(RuntimeError) { assert_snapshot("second") }
      assert_match(/multiple snapshots with implied name/, err.message)
    end
  end

  def test_explicit_names_skip_uniqueness_check
    with_sandbox do
      silence_warn do
        assert_snapshot("first", "explicit_one")
        assert_snapshot("second", "explicit_two")
      end

      assert(File.exist?(fixture_path_for("explicit_one", ".txt")))
      assert(File.exist?(fixture_path_for("explicit_two", ".txt")))
    end
  end

  def test_assert_snapshot_dir_renders_tree_and_contents
    with_sandbox do
      dir = @sandbox.join("sample_dir")
      dir.mkpath
      dir.join("a.txt").write("alpha\n")
      dir.join("sub").mkpath
      dir.join("sub/b.txt").write("beta\n")
      dir.join("img.png").binwrite("\x89PNG\r\n\x1a\nfake")

      silence_warn { assert_snapshot_dir(dir) }

      snap = File.read(fixture_path_for("test_snapshot/assert_snapshot_dir_renders_tree_and_contents", ".txt"))
      assert_match(/== tree ==/, snap)
      assert_match(/a\.txt/, snap)
      assert_match(/sub\//, snap)
      assert_match(/b\.txt/, snap)
      assert_match(/binary \.png file, size=\d+, xxh64=[0-9a-f]{16}/, snap)
      assert_match(/== file: a\.txt ==/, snap)
      assert_match(/alpha/, snap)
    end
  end

  def test_assert_snapshot_dir_detects_same_size_binary_changes
    with_sandbox do
      dir = @sandbox.join("sample_dir")
      dir.mkpath
      img_path = dir.join("img.png")
      img_path.binwrite("AAAA")

      silence_warn { assert_snapshot_dir(dir, "binary_dir") }
      first = File.read(fixture_path_for("binary_dir", ".txt"))

      img_path.binwrite("BBBB")

      captured_stderr = StringIO.new
      orig = $stderr
      $stderr = captured_stderr
      begin
        assert_snapshot_dir(dir, "binary_dir")
      ensure
        $stderr = orig
      end

      second = File.read(fixture_path_for("binary_dir", ".txt"))
      refute_equal(first, second)
      assert_match(/Snapshot changed/, captured_stderr.string)
    end
  end

  def test_snapshot_cache_writes_on_miss_and_reads_on_hit
    with_sandbox do
      path = fixture_path_for("test_snapshot/snapshot_cache_writes_on_miss_and_reads_on_hit", ".json")
      calls = 0

      result1 = snapshot_cache { calls += 1; {value: 42} }
      assert_equal({value: 42}, result1)
      assert_equal(1, calls)
      assert(File.exist?(path))

      result2 = snapshot_cache { calls += 1; {value: 999} }
      assert_equal({value: 42}, result2)
      assert_equal(1, calls)
    end
  end

  def test_snapshot_cache_reads_from_cache_on_miss_too
    with_sandbox do
      result1 = snapshot_cache("string_keys") { {"value" => 42} }
      result2 = snapshot_cache("string_keys") { {"value" => 999} }

      assert_equal({value: 42}, result1)
      assert_equal({value: 42}, result2)
    end
  end

  def test_fixtures_dir_required
    with_sandbox do
      Sfb::Test::Snapshot.fixtures_dir = nil
      err = assert_raises(RuntimeError) { assert_snapshot("x") }
      assert_match(/fixtures_dir must be set/, err.message)
    end
  end
end
