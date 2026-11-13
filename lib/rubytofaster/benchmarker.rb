# frozen_string_literal: true

require "fileutils"
require "open3"
require "rubygems/package"
require "tmpdir"

module RubyToFaster
  # Controlled benchmark runner comparing standard `gem build` CLI, `Gem::Package.build`,
  # `RubyToFaster` cold deterministic builds, and `RubyToFaster` incremental Merkle cache hits.
  class Benchmarker
    def initialize(root_dir: Dir.pwd, iterations: 5)
      @root_dir   = File.expand_path(root_dir)
      @iterations = [iterations.to_i, 1].max
    end

    def run
      config = Config.new(root_dir: @root_dir)
      spec, spec_path = FileResolver.new(config).load_gemspec

      Dir.mktmpdir("rtf-bench-") do |tmp_dir|
        results = []

        if spec_path && File.file?(spec_path)
          results << measure_case("gem build (CLI subprocess)", [2, @iterations].min) do
            out_gem = File.join(tmp_dir, "cli.gem")
            _o, _e, st = Open3.capture3("gem", "build", spec_path, "--output", out_gem, chdir: @root_dir)
            raise BuildError, "gem build failed during benchmark" unless st.success?
          end
        end

        results << measure_case("Gem::Package.build (in-process)", @iterations) do
          Dir.chdir(@root_dir) do
            out_gem = File.join(tmp_dir, "gem_pkg.gem")
            cloned = spec.dup
            silence_rubygems_ui { Gem::Package.build(cloned, true, false, out_gem) }
          end
        end

        results << measure_case("RubyToFaster (cold deterministic)", @iterations) do
          RubyToFaster.build(root_dir: @root_dir, report: false) do |pkg|
            pkg.gemspec(spec_path) if spec_path
            pkg.incremental = false
            pkg.output_dir File.join(tmp_dir, "rtf-cold")
          end
        end

        # Warm the Merkle cache once before measuring cache-hit latency
        cache_dir = File.join(tmp_dir, "rtf-cache")
        warm_out  = File.join(tmp_dir, "rtf-warm")
        RubyToFaster.build(root_dir: @root_dir, report: false) do |pkg|
          pkg.gemspec(spec_path) if spec_path
          pkg.cache true, dir: cache_dir
          pkg.output_dir warm_out
        end

        results << measure_case("RubyToFaster (Merkle cache hit)", @iterations) do
          RubyToFaster.build(root_dir: @root_dir, report: false) do |pkg|
            pkg.gemspec(spec_path) if spec_path
            pkg.cache true, dir: cache_dir
            pkg.output_dir warm_out
          end
        end

        baseline_ms = results.first[:mean_ms]
        results.each do |row|
          row[:speedup_vs_baseline] = row[:mean_ms].positive? ? (baseline_ms / row[:mean_ms]).round(1) : 1.0
        end

        {
          ruby_version: RUBY_VERSION,
          platform: RUBY_PLATFORM,
          gem_name: spec.name,
          iterations: @iterations,
          benchmarks: results
        }
      end
    end

    def format_markdown(report)
      lines = [
        "### Benchmark: `#{report[:gem_name]}` (Ruby #{report[:ruby_version]} on `#{report[:platform]}`)",
        "",
        "| Strategy | Mean (ms) | Min (ms) | P95 (ms) | Speedup |",
        "| :--- | ---: | ---: | ---: | ---: |"
      ]
      report[:benchmarks].each do |b|
        lines << format(
          "| %s | %.2f ms | %.2f ms | %.2f ms | **%.1fx** |",
          b[:name], b[:mean_ms], b[:min_ms], b[:p95_ms], b[:speedup_vs_baseline]
        )
      end
      lines.join("\n")
    end

    private

    def measure_case(name, count)
      samples = []
      count.times do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        yield
        samples << (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - t0)
      end

      sorted = samples.sort
      mean   = sorted.sum / sorted.size.to_f
      p95_ix = [(sorted.size * 0.95).ceil - 1, 0].max

      {
        name: name,
        runs: count,
        mean_ms: mean.round(2),
        min_ms: sorted.first.round(2),
        p95_ms: sorted[p95_ix].round(2)
      }
    end

    def silence_rubygems_ui(&block)
      Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new, &block)
    end
  end
end
