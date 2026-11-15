# frozen_string_literal: true

require "etc"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "time"
require "tmpdir"

module RubyToFaster
  # Controlled benchmark runner comparing standard `gem build` CLI, `Gem::Package.build`,
  # `RubyToFaster` cold deterministic builds, and `RubyToFaster` incremental Merkle cache hits.
  # Supports rendering real measured speed scores directly into an animated GIF89a report.
  class Benchmarker
    def initialize(root_dir: Dir.pwd, iterations: 5, warmup: 1)
      @root_dir   = File.expand_path(root_dir)
      @iterations = [iterations.to_i, 1].max
      @warmup     = [warmup.to_i, 0].max
    end

    def run
      script_path = CLI::DEFAULT_SCRIPT_NAMES.map { |n| File.join(@root_dir, n) }.find { |p| File.file?(p) }
      base_config = script_path ? RubyToFaster.load_script_config(script_path) : Config.new(root_dir: @root_dir)
      spec, spec_path = FileResolver.new(base_config).load_gemspec

      Dir.mktmpdir("rtf-bench-") do |tmp_dir|
        results = []

        if spec_path && File.file?(spec_path)
          cli_runs = [@iterations, 5].min
          results << measure_case("gem build (CLI subprocess)", cli_runs, warmup: [@warmup, 1].min) do
            out_gem = File.join(tmp_dir, "cli.gem")
            _o, _e, st = Open3.capture3("gem", "build", spec_path, "--output", out_gem, chdir: @root_dir)
            raise BuildError, "gem build failed during benchmark" unless st.success?
          end
        end

        results << measure_case("Gem::Package.build (in-process)", @iterations, warmup: @warmup) do
          RubyToFaster.with_chdir(@root_dir) do
            out_gem = File.join(tmp_dir, "gem_pkg.gem")
            cloned = spec.dup
            silence_rubygems_ui { Gem::Package.build(cloned, true, false, out_gem) }
          end
        end

        last_build_res = nil
        results << measure_case("RubyToFaster (cold deterministic)", @iterations, warmup: @warmup) do
          cfg = build_bench_config(script_path, spec_path)
          cfg.incremental = false
          cfg.quiet       = true
          cfg.output_dir File.join(tmp_dir, "rtf-cold")
          last_build_res = Compiler.new(cfg).run
        end

        # Warm the Merkle cache once before measuring cache-hit latency
        cache_dir = File.join(tmp_dir, "rtf-cache")
        warm_out  = File.join(tmp_dir, "rtf-warm")
        warm_cfg  = build_bench_config(script_path, spec_path)
        warm_cfg.cache(true, dir: cache_dir)
        warm_cfg.quiet = true
        warm_cfg.output_dir(warm_out)
        Compiler.new(warm_cfg).run

        results << measure_case("RubyToFaster (Merkle cache hit)", @iterations, warmup: @warmup) do
          cfg = build_bench_config(script_path, spec_path)
          cfg.cache(true, dir: cache_dir)
          cfg.quiet = true
          cfg.output_dir(warm_out)
          last_build_res = Compiler.new(cfg).run
        end

        baseline_ms = results.first[:mean_ms]
        results.each do |row|
          row[:speedup_vs_baseline] = row[:mean_ms].positive? ? (baseline_ms / row[:mean_ms]).round(1) : 1.0
        end

        cold_row  = results.find { |r| r[:name].include?("cold") }
        cache_row = results.find { |r| r[:name].include?("cache") }

        {
          rubytofaster_version: RubyToFaster::VERSION,
          ruby_version: RUBY_VERSION,
          ruby_description: RUBY_DESCRIPTION,
          platform: RUBY_PLATFORM,
          cpu_cores: [Etc.nprocessors, 1].max,
          gem_name: spec.name,
          gem_version: spec.version.to_s,
          entry_count: last_build_res&.entry_count || Array(spec.files).size,
          compressed_bytes: last_build_res&.compressed_bytes || 0,
          unpacked_bytes: last_build_res&.unpacked_bytes || 0,
          gem_sha256: last_build_res&.gem_sha256,
          git_sha: detect_git_sha,
          measured_at: Time.now.utc.iso8601,
          iterations: @iterations,
          warmup: @warmup,
          cold_speedup: cold_row ? cold_row[:speedup_vs_baseline] : 1.0,
          cache_speedup: cache_row ? cache_row[:speedup_vs_baseline] : 1.0,
          peak_speedup: results.map { |r| r[:speedup_vs_baseline] }.max || 1.0,
          benchmarks: results
        }
      end
    end

    def format_markdown(report)
      lines = [
        "### Benchmark: `#{report[:gem_name]}` v#{report[:gem_version]} (Ruby #{report[:ruby_version]} on `#{report[:platform]}`)",
        "",
        "| Strategy | Mean (ms) | Median (ms) | Min (ms) | P95 (ms) | Ops/sec | Speedup |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: |"
      ]
      report[:benchmarks].each do |b|
        lines << format(
          "| %s | %.2f ms | %.2f ms | %.2f ms | %.2f ms | %.1f/s | **%.1fx** |",
          b[:name],
          b[:mean_ms],
          b[:median_ms] || b[:mean_ms],
          b[:min_ms],
          b[:p95_ms],
          b[:ops_per_sec] || (b[:mean_ms].positive? ? 1000.0 / b[:mean_ms] : 0.0),
          b[:speedup_vs_baseline]
        )
      end
      lines.join("\n")
    end

    def write_gif(report, gif_path)
      GifRenderer.render_benchmark(report, gif_path)
      File.expand_path(gif_path)
    end

    def write_json(report, json_path)
      full = File.expand_path(json_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "#{JSON.pretty_generate(report)}\n")
      full
    end

    def write_markdown(report, md_path)
      full = File.expand_path(md_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "#{format_markdown(report)}\n")
      full
    end

    private

    def build_bench_config(script_path, spec_path)
      if script_path
        RubyToFaster.load_script_config(script_path)
      else
        cfg = Config.new(root_dir: @root_dir)
        cfg.gemspec(spec_path) if spec_path
        cfg
      end
    end

    def measure_case(name, count, warmup: 0)
      warmup.times { yield }
      GC.start

      samples = []
      count.times do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        yield
        samples << (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - t0)
      end

      sorted = samples.sort
      n      = sorted.size
      mean   = sorted.sum / n.to_f
      median = n.odd? ? sorted[n / 2] : (sorted[(n / 2) - 1] + sorted[n / 2]) / 2.0
      p95_ix = [(n * 0.95).ceil - 1, 0].max
      variance = sorted.sum { |x| (x - mean)**2 } / n.to_f
      stddev   = Math.sqrt(variance)

      {
        name: name,
        runs: count,
        mean_ms: mean.round(2),
        median_ms: median.round(2),
        min_ms: sorted.first.round(2),
        max_ms: sorted.last.round(2),
        p95_ms: sorted[p95_ix].round(2),
        stddev_ms: stddev.round(2),
        ops_per_sec: mean.positive? ? (1000.0 / mean).round(1) : 0.0
      }
    end

    def detect_git_sha
      out, _err, st = Open3.capture3("git", "rev-parse", "--short=8", "HEAD", chdir: @root_dir)
      st.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    def silence_rubygems_ui(&block)
      Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new, &block)
    end
  end
end
