# frozen_string_literal: true

require_relative "lib/cronwatch/version"

Gem::Specification.new do |spec|
  spec.name = "cronwatch"
  spec.version = Cronwatch::VERSION
  spec.authors = ["Jon C. Phillips"]
  spec.summary = "Cron and scheduled-job monitoring that lives inside your app."
  spec.description = "Wrap a job, run a check, get told when it is missed, failed, stuck, slow or over budget. " \
                     "The Ruby port of @cronwatch/sdk: same rules, same alerts, same stored rows."
  spec.homepage = "https://cronwatch.dev"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/phillips-jon/cronwatch/tree/main/packages/ruby",
    "changelog_uri" => "https://github.com/phillips-jon/cronwatch/releases",
    "bug_tracker_uri" => "https://github.com/phillips-jon/cronwatch/issues",
    "documentation_uri" => "https://cronwatch.dev/docs/ruby/",
    "rubygems_mfa_required" => "true",
  }

  # Globbed from this file's directory, so the list is the same whatever the working directory.
  spec.files = Dir.glob("lib/**/*.rb", base: __dir__) + %w[README.md LICENSE]
  spec.require_paths = ["lib"]

  spec.add_dependency "fugit", "~> 1.11"
end
