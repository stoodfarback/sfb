# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "sfb"
  spec.version       = "0.1.0"
  spec.authors       = ["stoodfarback"]
  spec.email         = ["stoodfarback@gmail.com"]

  spec.summary       = "My most commonly used gems & some misc utilities."
  spec.homepage      = "https://example.com"
  spec.required_ruby_version = Gem::Requirement.new(">= 3.2.0")

  spec.metadata["allowed_push_host"] = "Set to 'http://mygemserver.com'"

  spec.metadata["homepage_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    %x(git ls-files -z).split("\x0").reject {|f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) {|f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("actionview")
  spec.add_dependency("activesupport", ">= 6.0")
  spec.add_dependency("base32-crockford")
  spec.add_dependency("http")
  spec.add_dependency("nokogiri")
  spec.add_dependency("oj")

  spec.add_dependency("pry")

  spec.add_dependency("redis")
  spec.add_dependency("rubocop")
  spec.add_dependency("xxhash")

  spec.add_dependency("minitest")
end
