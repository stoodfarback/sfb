#!/usr/bin/env ruby
# frozen_string_literal: true

projects_dir = File.expand_path("../..", __dir__)

Dir.children(projects_dir).sort.each do |name|
  project_path = File.join(projects_dir, name)
  next unless File.directory?(project_path)
  next unless File.exist?(File.join(project_path, ".git"))
  next unless File.exist?(File.join(project_path, "Gemfile.lock"))

  Dir.chdir(project_path) do
    puts("\n=== #{name} ===")

    has_origin = system("git remote get-url origin >/dev/null 2>&1")
    clean = %x(git status --porcelain).strip.empty?

    if has_origin && clean
      system("git push")
      system("git pull")
    end

    system("bundle update --conservative sfb")

    status = %x(git status --porcelain).strip
    only_lockfile_changed = (status == "M Gemfile.lock" || status == " M Gemfile.lock")

    if only_lockfile_changed
      system("git add Gemfile.lock")
      system("git commit -m 'bundle update --conservative sfb'")
    end

    has_origin = system("git remote get-url origin >/dev/null 2>&1")
    clean = %x(git status --porcelain).strip.empty?

    if has_origin && clean
      system("git push")
      system("git pull")
    end
  end
end
