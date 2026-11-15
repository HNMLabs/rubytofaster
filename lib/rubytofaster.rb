# frozen_string_literal: true

require "monitor"

require_relative "rubytofaster/version"
require_relative "rubytofaster/errors"
require_relative "rubytofaster/config"
require_relative "rubytofaster/plugin"
require_relative "rubytofaster/plugins"
require_relative "rubytofaster/file_resolver"
require_relative "rubytofaster/cache"
require_relative "rubytofaster/asset_manifest"
require_relative "rubytofaster/middleware"
require_relative "rubytofaster/resources/base"
require_relative "rubytofaster/resources/vite"
require_relative "rubytofaster/resources/nextjs"
require_relative "rubytofaster/resources/angular"
require_relative "rubytofaster/extension_builder"
require_relative "rubytofaster/budget"
require_relative "rubytofaster/packager"
require_relative "rubytofaster/inspector"
require_relative "rubytofaster/analyzer"
require_relative "rubytofaster/compiler"
require_relative "rubytofaster/workspace"
require_relative "rubytofaster/scaffolder"
require_relative "rubytofaster/gif_renderer"
require_relative "rubytofaster/benchmarker"
require_relative "rubytofaster/reporter"
require_relative "rubytofaster/cli"

# RubyToFaster: Minimalist, script-first build system for Ruby gems
# with native resource pipelines for Angular, Vite, and Next.js.
module RubyToFaster
  CHDIR_MONITOR = Monitor.new

  class << self
    def pending_script_capture
      Thread.current[:rtf_pending_script_capture]
    end

    def pending_script_capture=(callable)
      Thread.current[:rtf_pending_script_capture] = callable
    end

    # Synchronizes process-wide `Dir.chdir` when loading `.gemspec` or build scripts across threads.
    def with_chdir(dir, &block)
      target = File.expand_path(dir)
      CHDIR_MONITOR.synchronize do
        if File.expand_path(Dir.pwd) == target
          block.call
        else
          Dir.chdir(target, &block)
        end
      end
    end

    # Executes a gem build directly from a Ruby script or caller.
    def build(root_dir: nil, report: nil, out: $stdout)
      effective_root = root_dir || Thread.current[:rtf_default_root_dir] || Dir.pwd
      config = Config.new(root_dir: effective_root)
      yield(config) if block_given?

      if (capture = pending_script_capture)
        capture.call(config)
        return nil
      end

      result = Compiler.new(config).run
      should_report = report.nil? ? !config.quiet : report
      Reporter.new(io: out, quiet: !should_report, verbose: config.verbose).report_build(result) if should_report
      result
    end

    # Defines a reusable Config object without immediately running the compiler.
    def define(root_dir: nil)
      effective_root = root_dir || Thread.current[:rtf_default_root_dir] || Dir.pwd
      config = Config.new(root_dir: effective_root)
      yield(config) if block_given?
      pending_script_capture&.call(config)
      config
    end

    # Executes topological parallel builds across a multi-gem monorepo workspace.
    def workspace(root_dir: Dir.pwd, patterns: nil, parallel_jobs: nil, incremental: true)
      Workspace.new(
        root_dir: root_dir,
        patterns: patterns,
        parallel_jobs: parallel_jobs,
        incremental: incremental
      ).build_all
    end

    # Runs real hardware build benchmarks and optionally writes GIF89a, JSON, or Markdown artifacts.
    def bench(root_dir: Dir.pwd, iterations: 5, warmup: 1, gif_out: nil, json_out: nil, markdown_out: nil)
      runner = Benchmarker.new(root_dir: root_dir, iterations: iterations, warmup: warmup)
      report = runner.run
      runner.write_gif(report, gif_out) if gif_out
      runner.write_json(report, json_out) if json_out
      runner.write_markdown(report, markdown_out) if markdown_out
      report
    end

    # Inspects and verifies an existing `.gem` file without extracting to disk.
    def inspect_gem(gem_path)
      Inspector.inspect_gem(gem_path)
    end

    # Analyzes unpacked vs gzipped composition of a `.gem` package.
    def analyze_gem(gem_path, html_out: nil)
      analyzer = Analyzer.new(gem_path)
      data = analyzer.analyze
      analyzer.write_html_report(data, html_out) if html_out
      data
    end

    # Loads a standalone compiler script (`gem.build.rb`) and captures its Config in a thread-safe manner.
    def load_script_config(script_path)
      abs_script = File.expand_path(script_path)
      script_dir = File.dirname(abs_script)
      captured = nil

      prev_capture = pending_script_capture
      prev_root    = Thread.current[:rtf_default_root_dir]
      self.pending_script_capture = ->(cfg) { captured = cfg }
      Thread.current[:rtf_default_root_dir] = script_dir

      with_chdir(script_dir) do
        Kernel.load(abs_script, true)
      end

      captured || Config.new(root_dir: script_dir)
    ensure
      self.pending_script_capture = prev_capture
      Thread.current[:rtf_default_root_dir] = prev_root
    end
  end
end
