# frozen_string_literal: true

require("fileutils")
require("pathname")

# Snapshot testing helper for Minitest.
#
# Setup (typically in `test/test_helper.rb`):
#   Sfb::Test::Snapshot.setup!
#   # or: Sfb::Test::Snapshot.setup!(dir: "custom/dir", skip_common_gsubs: true)
#
# Golden path:
#   assert_snapshot(actual)                # implied name from class + test method
#   assert_snapshot(actual, "my/key")      # explicit key (trusted to be unique)
#   assert_snapshot_dir("/tmp/out_dir")    # tree + file contents (binary files summarized)
#   snapshot_cache("label") { expensive }  # JSON cache in `fixtures_dir`
#
# Fixtures live under `fixtures_dir` (default: `test/fixtures/snapshots`).
# They are auto-created/updated; review via git diff and commit fixture changes.
#
# By default a few common regex gsubs are applied (timestamps/IPs). Add your own via:
#   Sfb::Test::Snapshot.gsubs << [/\\b\\d+ms\\b/, "GSUB_MS"]
#
# Strict mode (CI): set ENV["SFB_SNAPSHOT_STRICT"]=1 to flunk on mismatch instead of overwriting.

module Sfb::Test::Snapshot
  BINARY_EXTS = %w[.jpg .jpeg .png .gif .webp .pdf .mmdb .ico .woff .woff2 .ttf .otf .zip .gz].freeze

  COMMON_GSUBS = [
    [/20\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} -\d{4}/, "GSUB_TIMESTAMP_TZ"],
    [/20\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, "GSUB_TIMESTAMP"],
    [/20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/, "GSUB_ISO8601"],
    [/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, "GSUB_IP"],
  ].freeze

  class << self
    attr_accessor(:fixtures_dir, :gsubs)

    def setup!(dir: "test/fixtures/snapshots", skip_common_gsubs: false)
      require("minitest/test")
      self.fixtures_dir = dir
      self.gsubs = skip_common_gsubs ? [] : COMMON_GSUBS.deep_dup
      Minitest::Test.include(self)
      nil
    end

    def fixtures_dir!
      fixtures_dir || raise("Sfb::Test::Snapshot.fixtures_dir must be set")
    end

    def normalize_txt(value)
      text = value.to_s.gsub(/\r\n?/, "\n")
      text = text.lines.map { it.sub(/[ \t]+$/, "") }.join
      text = text.gsub(/\A(?:[ \t]*\n)+/, "")
      text = text.gsub(/(?:\n[ \t]*)+\z/, "")
      text
    end

    def gsub_in_structure(val, from, to)
      case val
      when String
        val.gsub(from, to)
      when Hash
        val.to_h {|k, v| [gsub_in_structure(k, from, to), gsub_in_structure(v, from, to)] }
      when Array
        val.map { gsub_in_structure(it, from, to) }
      else
        val
      end
    end

    def apply_gsubs(val)
      Array(gsubs).reduce(val) {|acc, (from, to)| gsub_in_structure(acc, from, to) }
    end

    def strict?
      !ENV["SFB_SNAPSHOT_STRICT"].to_s.empty?
    end
  end

  def assert_snapshot(actual, name = nil, ext: nil)
    cfg = Sfb::Test::Snapshot
    is_string = actual.is_a?(String)
    ext ||= is_string ? ".txt" : ".yml"

    normalized = cfg.apply_gsubs(actual)
    serialized = is_string ? cfg.normalize_txt(normalized) : YAML.dump(normalized)

    key = name || snapshot_derive_name
    if name.nil?
      @sfb_snapshot_taken ||= []
      if @sfb_snapshot_taken.include?(key)
        raise("Sfb::Test::Snapshot: multiple snapshots with implied name '#{key}' in #{self.class}##{self.name}. Pass an explicit name to disambiguate.")
      end
      @sfb_snapshot_taken << key
    end

    fixture_path = File.join(cfg.fixtures_dir!, "#{key}#{ext}")

    if !File.exist?(fixture_path)
      FileUtils.mkdir_p(File.dirname(fixture_path))
      File.write(fixture_path, serialized)
      warn("\n\e[1;33mCreated new snapshot:\e[0m #{fixture_path}")
      return(pass)
    end

    expected_raw = File.read(fixture_path)
    expected = is_string ? cfg.normalize_txt(expected_raw) : expected_raw
    return(pass) if serialized == expected

    if cfg.strict?
      flunk("Sfb::Test::Snapshot mismatch for #{fixture_path}\nexpected:\n#{expected}\n\nactual:\n#{serialized}")
    end

    File.write(fixture_path, serialized)
    warn("\n\e[1;33mSnapshot changed:\e[0m #{fixture_path}")
    pass
  end

  def assert_snapshot_dir(dir_path, name = nil)
    dir = Pathname(dir_path)
    raise("snapshot dir does not exist: #{dir}") if !dir.directory?

    lines = []
    lines << "dir=<SNAPSHOT_DIR>"
    lines << "== tree =="
    lines.concat(snapshot_render_tree(dir))

    file_paths = dir.glob("**/*", File::FNM_DOTMATCH).
      select(&:file?).
      reject { it.basename.to_s == "." || it.basename.to_s == ".." }.
      sort_by { it.relative_path_from(dir).to_s }

    file_paths.each do |path|
      rel = path.relative_path_from(dir).to_s
      lines << ""
      lines << "== file: #{rel} =="
      lines << snapshot_file_text(path)
    end

    assert_snapshot(lines.join("\n"), name)
  end

  def snapshot_cache(name = nil)
    key = snapshot_derive_name
    key = "#{key}/#{name}" if !name.nil?
    fixture_path = File.join(Sfb::Test::Snapshot.fixtures_dir!, "#{key}.json")

    if File.exist?(fixture_path)
      return(snapshot_cache_read(fixture_path))
    end

    result = yield
    FileUtils.mkdir_p(File.dirname(fixture_path))
    File.write(fixture_path, JSON.pretty_generate(result))
    snapshot_cache_read(fixture_path)
  end

  def snapshot_cache_read(fixture_path)
    JSON.parse(File.read(fixture_path), symbolize_names: true)
  end

  def snapshot_derive_name
    parts = []
    self.class.name.delete_suffix("Test").split("::").each { parts << it.underscore }
    parts << self.name.delete_prefix("test_")
    parts.reject(&:empty?).join("/")
  end

  def snapshot_render_tree(root)
    entries = root.children.sort_by { it.basename.to_s }
    return(["(empty)"]) if entries.empty?

    snapshot_render_tree_entries(entries, prefix: "")
  end

  def snapshot_render_tree_entries(entries, prefix:)
    lines = []

    entries.each_with_index do |entry, idx|
      is_last = idx == entries.length - 1
      branch = is_last ? "└─ " : "├─ "
      child_prefix = prefix + (is_last ? "   " : "│  ")
      label = entry.basename.to_s
      label = "#{label}/" if entry.directory?
      lines << "#{prefix}#{branch}#{label}"

      if entry.directory?
        child_entries = entry.children.sort_by { it.basename.to_s }
        lines.concat(snapshot_render_tree_entries(child_entries, prefix: child_prefix)) if child_entries.any?
      end
    end

    lines
  end

  def snapshot_file_text(path)
    ext = path.extname.downcase
    if BINARY_EXTS.include?(ext)
      hash = format("%016x", XXhash.xxh64_file(path.to_s))
      return("<binary #{ext} file, size=#{path.size}, xxh64=#{hash}>")
    end

    text = File.read(path)
    text.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
  end
end
