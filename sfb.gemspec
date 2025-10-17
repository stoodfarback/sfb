# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "sfb"
  spec.version = "0.1.0"
  spec.authors = ["stoodfarback"]
  spec.email = ["stoodfarback@gmail.com"]

  spec.summary = "My most commonly used gems & some misc utilities."
  spec.homepage = "https://example.com"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["allowed_push_host"] = "Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("actionview")
  spec.add_dependency("activesupport", ">= 6.0")
  spec.add_dependency("base32-crockford")
  spec.add_dependency("http")
  spec.add_dependency("nokogiri")
  spec.add_dependency("oj")

  spec.add_dependency("reline")
  spec.add_dependency("pry")

  spec.add_dependency("redis")
  spec.add_dependency("rubocop")
  spec.add_dependency("xxhash")
  spec.add_dependency("msgpack")
  spec.add_dependency("pstore")

  spec.add_dependency("minitest")

  # tmp explicit dependency on openssl to fix openssl compat issue
  spec.add_dependency("openssl")
end
