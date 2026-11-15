# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "rbconfig"

module RubyToFaster
  # Minimalist zero-dependency command-line interface (`rubytofaster` / `rtf`).
  class CLI
    DEFAULT_SCRIPT_NAMES = %w[gem.build.rb build.rtf.rb Fastbuild.rb].freeze

    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(argv, out: out, err: err).run
    end

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out  = out
      @err  = err
    end

    def run
      if @argv.first == "-v" || @argv.first == "--version"
        @out.puts "rubytofaster #{RubyToFaster::VERSION}"
        return 0
      end

      if @argv.first == "-h" || @argv.first == "--help"
        print_help
        return 0
      end

      command = if @argv.empty? || @argv.first.start_with?("-")
                  "build"
                else
                  @argv.shift
                end

      case command
      when "build"     then cmd_build
      when "new"       then cmd_new
      when "init"      then cmd_init
      when "inspect"   then cmd_inspect
      when "analyze"   then cmd_analyze
      when "workspace" then cmd_workspace
      when "bench"     then cmd_bench
      when "clean"     then cmd_clean
      when "doctor"    then cmd_doctor
      when "watch"     then cmd_watch
      when "version"
        @out.puts "rubytofaster #{RubyToFaster::VERSION}"
        0
      when "help"
        print_help
        0
      else
        if File.file?(command)
          @argv.unshift(command)
          cmd_build
        else
          @err.puts "Unknown command: #{command}. Run `rtf --help` for usage."
          1
        end
      end
    rescue RubyToFaster::Error => e
      @err.puts "[RubyToFaster::#{e.class.name.split('::').last}] #{e.message}"
      1
    end

    private

    def cmd_build
      opts = {
        incremental: true,
        skip_assets: false,
        skip_extensions: false,
        sbom: false,
        provenance: false,
        out_dir: nil,
        json: false,
        quiet: false,
        verbose: false
      }

      OptionParser.new do |o|
        o.banner = "Usage: rtf build [gem.build.rb | my_gem.gemspec] [options]"
        o.on("--no-cache", "Disable content-addressable incremental cache") { opts[:incremental] = false }
        o.on("--skip-assets", "Skip Angular, Vite, and Next.js resource collection") { opts[:skip_assets] = true }
        o.on("--skip-extensions", "Skip native extension compilation check") { opts[:skip_extensions] = true }
        o.on("--sbom", "Emit CycloneDX 1.5 SBOM (.sbom.cdx.json) alongside built gem") { opts[:sbom] = true }
        o.on("--provenance", "Emit .sha256 and SLSA v1 .provenance.json attestation") { opts[:provenance] = true }
        o.on("-o", "--out-dir DIR", "Output directory for built .gem (default: pkg)") { |d| opts[:out_dir] = d }
        o.on("--json", "Emit structured JSON build summary") { opts[:json] = true }
        o.on("-q", "--quiet", "Suppress terminal output") { opts[:quiet] = true }
        o.on("-V", "--verbose", "Show per-stage monotonic timing breakdown") { opts[:verbose] = true }
      end.parse!(@argv)

      target = @argv.first
      result = execute_build_target(target, opts)
      Reporter.new(io: @out, json: opts[:json], quiet: opts[:quiet], verbose: opts[:verbose]).report_build(result)
      0
    end

    def execute_build_target(target, opts)
      script_path = resolve_script_target(target)
      if script_path
        config = RubyToFaster.load_script_config(script_path)
        apply_cli_overrides!(config, opts)
        return Compiler.new(config).run
      end

      if target && target.end_with?(".gemspec")
        spec_abs = File.expand_path(target)
        spec_dir = File.dirname(spec_abs)
        return RubyToFaster.build(root_dir: spec_dir, report: false) do |cfg|
          cfg.gemspec(File.basename(spec_abs))
          # Preserve relative --out-dir relative to caller's working directory when explicitly passed
          opts = opts.merge(out_dir: File.expand_path(opts[:out_dir], Dir.pwd)) if opts[:out_dir]
          apply_cli_overrides!(cfg, opts)
        end
      end

      RubyToFaster.build(root_dir: Dir.pwd, report: false) do |cfg|
        apply_cli_overrides!(cfg, opts)
      end
    end

    def resolve_script_target(target)
      if target
        raise ConfigError, "Target file not found: #{target}" unless File.file?(target)

        return File.expand_path(target) if target.end_with?(".rb")

        return nil
      end

      found = DEFAULT_SCRIPT_NAMES.find { |name| File.file?(name) }
      found ? File.expand_path(found) : nil
    end

    def apply_cli_overrides!(config, opts)
      config.incremental     = false unless opts.fetch(:incremental, true)
      config.skip_assets     = true  if opts[:skip_assets]
      config.skip_extensions = true  if opts[:skip_extensions]
      config.out_dir         = opts[:out_dir] if opts[:out_dir]
      config.quiet           = opts[:quiet] if opts.key?(:quiet)
      config.verbose         = opts[:verbose] if opts.key?(:verbose)
      config.generate_sbom       if opts[:sbom]
      config.generate_provenance if opts[:provenance]
    end

    def cmd_new
      opts = { vite: false, nextjs: false, angular: false, dir: nil }
      OptionParser.new do |o|
        o.banner = "Usage: rtf new <gem_name> [--vite] [--nextjs] [--angular]"
        o.on("--vite", "Scaffold Vite frontend workspace & manifest starter") { opts[:vite] = true }
        o.on("--nextjs", "Scaffold Next.js frontend workspace starter") { opts[:nextjs] = true }
        o.on("--angular", "Scaffold Angular Architect workspace starter") { opts[:angular] = true }
        o.on("--fullstack", "Scaffold Vite + Next.js + Angular workspaces") do
          opts[:vite] = opts[:nextjs] = opts[:angular] = true
        end
        o.on("-d", "--dir DIR", "Target directory") { |d| opts[:dir] = d }
      end.parse!(@argv)

      gem_name = @argv.first
      raise ConfigError, "Usage: rtf new <gem_name> [--vite] [--nextjs] [--angular]" unless gem_name

      created_dir = Scaffolder.new(
        gem_name,
        target_dir: opts[:dir],
        vite: opts[:vite],
        nextjs: opts[:nextjs],
        angular: opts[:angular]
      ).generate!

      @out.puts "Scaffolded new RubyToFaster gem '#{gem_name}' at #{created_dir}"
      0
    end

    def cmd_init
      opts = { vite: false, nextjs: false, angular: false, force: false, file: "gem.build.rb" }
      OptionParser.new do |o|
        o.banner = "Usage: rtf init [options]"
        o.on("--vite", "Include Vite resource pipeline configuration") { opts[:vite] = true }
        o.on("--nextjs", "Include Next.js resource pipeline configuration") { opts[:nextjs] = true }
        o.on("--angular", "Include Angular resource pipeline configuration") { opts[:angular] = true }
        o.on("-f", "--file PATH", "Script filename (default: gem.build.rb)") { |f| opts[:file] = f }
        o.on("--force", "Overwrite existing build script") { opts[:force] = true }
      end.parse!(@argv)

      dest = File.expand_path(opts[:file], Dir.pwd)
      if File.exist?(dest) && !opts[:force]
        raise ConfigError, "#{opts[:file]} already exists (pass --force to overwrite)."
      end

      gemspec_file = Dir.glob("*.gemspec").first || "my_gem.gemspec"
      lines = [
        "#!/usr/bin/env ruby",
        "# frozen_string_literal: true",
        "",
        'require "rubytofaster"',
        "",
        "RubyToFaster.build(root_dir: __dir__) do |pkg|",
        "  pkg.gemspec #{gemspec_file.dump}",
        "  pkg.incremental = true",
        "  pkg.validate_ruby_syntax"
      ]
      lines << '  pkg.vite root: "frontend", out_dir: "dist", mount_to: "public/vite"' if opts[:vite]
      lines << '  pkg.nextjs root: "web", mode: :auto, mount_to: "public/nextjs"' if opts[:nextjs]
      lines << '  pkg.angular root: "admin", mount_to: "public/angular"' if opts[:angular]
      lines << "  pkg.precompress_assets" if opts[:vite] || opts[:nextjs] || opts[:angular]
      lines << "  pkg.budget max_compressed_kb: 512, max_unpacked_kb: 2048"
      lines << "end"
      lines << ""

      File.write(dest, lines.join("\n"))
      File.chmod(0o755, dest)
      @out.puts "Created executable compiler script: #{opts[:file]}"
      0
    end

    def cmd_inspect
      json = false
      OptionParser.new do |o|
        o.banner = "Usage: rtf inspect <path/to/file.gem> [--json]"
        o.on("--json", "Emit JSON inspection output") { json = true }
      end.parse!(@argv)

      gem_file = @argv.first
      raise ConfigError, "Usage: rtf inspect <path/to/file.gem>" unless gem_file

      info = Inspector.inspect_gem(gem_file)
      Reporter.new(io: @out, json: json).report_inspection(info)
      0
    end

    def cmd_analyze
      json = false
      html_out = nil
      OptionParser.new do |o|
        o.banner = "Usage: rtf analyze <path/to/file.gem> [--html report.html] [--json]"
        o.on("--html FILE", "Generate interactive HTML bundle treemap report") { |f| html_out = f }
        o.on("--json", "Emit JSON analysis output") { json = true }
      end.parse!(@argv)

      gem_file = @argv.first
      raise ConfigError, "Usage: rtf analyze <path/to/file.gem> [--html report.html]" unless gem_file

      analyzer = Analyzer.new(gem_file)
      report = analyzer.analyze
      written_html = html_out ? analyzer.write_html_report(report, html_out) : nil

      if json
        @out.puts JSON.pretty_generate(report.merge(html_report: written_html))
      else
        @out.puts "Bundle Analysis: #{report[:gem_name]} v#{report[:gem_version]}"
        @out.puts format(
          "  Archive : %.2f KB compressed / %.2f KB unpacked (ratio %.1f%%, %d files)",
          report[:archive_bytes] / 1024.0,
          report[:unpacked_bytes] / 1024.0,
          report[:compression_ratio] * 100.0,
          report[:file_count]
        )
        @out.puts "  Categories:"
        report[:categories].each_value do |cat|
          @out.puts format(
            "    - %-22s %8.2f KB unpacked | %8.2f KB gzip (%5.1f%%, %d files)",
            cat[:label], cat[:unpacked_bytes] / 1024.0, cat[:gzip_bytes] / 1024.0, cat[:share_pct], cat[:file_count]
          )
        end
        @out.puts "  HTML Report: #{written_html}" if written_html
      end
      0
    end

    def cmd_workspace
      incremental = true
      json = false
      patterns = nil
      OptionParser.new do |o|
        o.banner = "Usage: rtf workspace [--patterns 'gems/*,packages/*'] [--no-cache] [--json]"
        o.on("--patterns GLOBS", "Comma-separated workspace globs") { |g| patterns = g.split(",").map(&:strip) }
        o.on("--no-cache", "Disable incremental Merkle cache") { incremental = false }
        o.on("--json", "Emit JSON workspace build summary") { json = true }
      end.parse!(@argv)

      ws_res = Workspace.new(root_dir: Dir.pwd, patterns: patterns, incremental: incremental).build_all
      if json
        @out.puts JSON.pretty_generate(
          waves: ws_res.waves,
          cache_hits: ws_res.cache_hits,
          total_gems: ws_res.results.size,
          total_ms: ws_res.total_ms,
          results: ws_res.results.map(&:to_h)
        )
      else
        @out.puts "Workspace Build Complete (#{ws_res.results.size} gems in #{ws_res.waves.size} topological waves, #{ws_res.total_ms}ms)"
        ws_res.waves.each_with_index do |wave, idx|
          @out.puts "  Wave #{idx + 1}: #{wave.join(', ')}"
        end
        ws_res.results.each do |r|
          tag = r.cache_hit ? "CACHE" : "BUILT"
          @out.puts format("    [%s] %-24s v%-8s (%6.2f KB, %.2fms)", tag, r.gem_name, r.gem_version, r.compressed_bytes / 1024.0, r.total_ms)
        end
      end
      0
    end

    def cmd_bench
      iterations = 5
      warmup     = 1
      json       = false
      gif_out    = nil
      json_out   = nil
      md_out     = nil

      OptionParser.new do |o|
        o.banner = "Usage: rtf bench [-n ITERATIONS] [-w WARMUP] [--gif FILE] [--json-out FILE] [--json]"
        o.on("-n", "--iterations N", Integer, "Benchmark iterations per strategy (default: 5)") { |n| iterations = n }
        o.on("-w", "--warmup N", Integer, "Warmup runs before timing each strategy (default: 1)") { |w| warmup = w }
        o.on("--gif FILE", "Render real measured speed scores as an animated GIF89a chart") { |f| gif_out = f }
        o.on("--json-out FILE", "Write structured JSON benchmark telemetry to FILE") { |f| json_out = f }
        o.on("--markdown-out FILE", "Write Markdown benchmark table to FILE") { |f| md_out = f }
        o.on("--json", "Emit JSON benchmark report to stdout") { json = true }
      end.parse!(@argv)

      bench  = Benchmarker.new(root_dir: Dir.pwd, iterations: iterations, warmup: warmup)
      report = bench.run

      written_gif  = gif_out  ? bench.write_gif(report, gif_out)      : nil
      written_json = json_out ? bench.write_json(report, json_out)    : nil
      written_md   = md_out   ? bench.write_markdown(report, md_out)  : nil

      output_payload = if written_gif || written_json || written_md
                         report.merge(
                           artifacts: {
                             gif: written_gif,
                             json: written_json,
                             markdown: written_md
                           }.compact
                         )
                       else
                         report
                       end

      if json
        @out.puts JSON.pretty_generate(output_payload)
      else
        @out.puts bench.format_markdown(report)
        @out.puts "\nAnimated GIF89a Speed Chart : #{written_gif}" if written_gif
        @out.puts "JSON Telemetry Report       : #{written_json}" if written_json
        @out.puts "Markdown Benchmark Table    : #{written_md}" if written_md
      end
      0
    end

    def cmd_clean
      cfg = Config.new(root_dir: Dir.pwd)
      Cache.new(cfg).clear!
      FileUtils.rm_rf(cfg.resolved_out_dir) if Dir.exist?(cfg.resolved_out_dir)
      @out.puts "Cleaned #{cfg.cache_dir}/ and #{cfg.out_dir}/"
      0
    end

    def cmd_doctor
      checks = {
        rubytofaster_version: RubyToFaster::VERSION,
        ruby_version: RUBY_VERSION,
        ruby_platform: RUBY_PLATFORM,
        rubygems_version: Gem::VERSION,
        gemspecs_found: Dir.glob("*.gemspec").sort,
        build_scripts_found: DEFAULT_SCRIPT_NAMES.select { |f| File.file?(f) },
        detected_frameworks: {
          vite: Resources::Vite.detect?(Dir.pwd),
          nextjs: Resources::Nextjs.detect?(Dir.pwd),
          angular: Resources::Angular.detect?(Dir.pwd)
        }
      }
      @out.puts JSON.pretty_generate(checks)
      0
    end

    def cmd_watch
      interval = 0.5
      max_cycles = nil
      OptionParser.new do |o|
        o.banner = "Usage: rtf watch [script_or_gemspec] [--interval SECONDS]"
        o.on("-i", "--interval SEC", Float, "Polling interval in seconds (default: 0.5)") { |s| interval = s }
        o.on("--cycles N", Integer, "Stop after N watch cycles (for automated testing)") { |n| max_cycles = n }
      end.parse!(@argv)

      target = @argv.first
      last_signature = nil
      cycles = 0

      @out.puts "Watching #{Dir.pwd} for changes (Ctrl+C to stop)..."
      loop do
        sig = workspace_mtime_signature
        if sig != last_signature
          last_signature = sig
          begin
            res = execute_build_target(target, { incremental: true })
            Reporter.new(io: @out).report_build(res)
          rescue RubyToFaster::Error => e
            @err.puts "[Build Error] #{e.message}"
          end
        end

        cycles += 1
        break if max_cycles && cycles >= max_cycles

        sleep(interval)
      end
      0
    rescue Interrupt
      @out.puts "\nStopped watch mode."
      0
    end

    def workspace_mtime_signature(base_dir = Dir.pwd)
      globs = "{lib,exe,bin,ext,sig,frontend,portal,admin,web,ui,public}/**/*"
      files = Dir.glob(globs, File::FNM_DOTMATCH, base: base_dir)
      files.concat(Dir.glob("{*.gemspec,gem.build.rb,build.rtf.rb,Fastbuild.rb}", base: base_dir))

      files.uniq.sort.filter_map do |rel|
        next if rel.include?("/node_modules/") || rel.start_with?(".git/", ".rtf-cache/", "pkg/")

        full = File.join(base_dir, rel)
        next unless File.file?(full)

        "#{rel}:#{File.mtime(full).to_f}"
      rescue Errno::ENOENT
        nil
      end.join("|")
    end

    def print_help
      @out.puts <<~HELP
        RubyToFaster (rtf) v#{RubyToFaster::VERSION}
        Minimalist, script-first Ruby gem compiler with Angular, Vite, and Next.js resources.

        Usage:
          rtf [build] [gem.build.rb | *.gemspec] [options]
          rtf new <gem_name> [--vite] [--nextjs] [--angular] [--fullstack]
          rtf init [--vite] [--nextjs] [--angular]
          rtf inspect <pkg/name-version.gem> [--json]
          rtf analyze <pkg/name-version.gem> [--html report.html] [--json]
          rtf workspace [--patterns 'gems/*,packages/*'] [--no-cache]
          rtf bench [-n ITERATIONS] [-w WARMUP] [--gif benchmarks.gif] [--json-out bench.json] [--json]
          rtf watch [gem.build.rb]
          rtf clean
          rtf doctor
          rtf version

        Build Options:
          --no-cache         Rebuild from scratch ignoring .rtf-cache
          --skip-assets      Skip frontend resource collection
          --skip-extensions  Skip native C/Rust extension verification
          --sbom             Emit CycloneDX 1.5 SBOM (.sbom.cdx.json)
          --provenance       Emit .sha256 & SLSA v1 .provenance.json attestation
          -o, --out-dir DIR  Output directory (default: pkg)
          --json             Output structured JSON metrics
          -q, --quiet        Suppress build output
          -V, --verbose      Print per-stage monotonic timings
      HELP
    end
  end
end
