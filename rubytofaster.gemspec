# frozen_string_literal: true

require_relative "lib/rubytofaster/version"

Gem::Specification.new do |spec|
  spec.name          = "rubytofaster"
  spec.version       = RubyToFaster::VERSION
  spec.authors       = ["HNM Labs"]
  spec.email         = ["opensource@hnmlabs.dev"]

  spec.summary       = "Minimalist, script-first build system for Ruby gems with Angular, Vite, and Next.js resource integration."
  spec.description   = <<~DESC.tr("\n", " ").strip
    RubyToFaster is a minimalist, high-speed build system and deterministic package compiler for Ruby gems.
    Execute gem builds directly as standalone Ruby scripts with content-addressable incremental caching,
    parallel native extension compilation, bundle budgets, and first-class resource adapters for Angular,
    Vite, and Next.js applications.
  DESC
  spec.homepage      = "https://github.com/HNMLabs/rubytofaster"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = "https://github.com/HNMLabs/rubytofaster"
  spec.metadata["changelog_uri"]         = "https://github.com/HNMLabs/rubytofaster/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"]     = "https://github.com/HNMLabs/rubytofaster/wiki"
  spec.metadata["bug_tracker_uri"]       = "https://github.com/HNMLabs/rubytofaster/issues"
  spec.metadata["security_policy_uri"]   = "https://github.com/HNMLabs/rubytofaster/blob/main/SECURITY.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{exe,lib,sig}/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } +
      %w[LICENSE README.md CHANGELOG.md SECURITY.md rubytofaster.gemspec]
  end.select { |f| File.exist?(File.join(__dir__, f)) }.uniq.sort

  spec.bindir        = "exe"
  spec.executables   = %w[rubytofaster rtf]
  spec.require_paths = ["lib"]
end
