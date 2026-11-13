# frozen_string_literal: true

require "etc"

module RubyToFaster
  # Minimalist script-first DSL configuration for RubyToFaster builds.
  class Config
    attr_reader :root_dir, :resources, :budgets, :plugins, :hooks,
                :extra_excludes, :extra_includes, :inline_spec_block
    attr_accessor :gemspec_path, :out_dir, :cache_dir, :incremental,
                  :reproducible, :source_date_epoch, :parallel_jobs,
                  :strict_security, :auto_detect_resources, :skip_assets,
                  :skip_extensions, :write_staged_assets, :quiet, :verbose,
                  :asset_helper_module, :asset_helper_path

    DEFAULT_EXCLUDES = [
      %r{\A\.git(/|\z)},
      %r{\A\.github(/|\z)},
      %r{\A\.rtf-cache(/|\z)},
      %r{\Apkg(/|\z)},
      %r{(?:\A|/)node_modules(/|\z)},
      %r{(?:\A|/)\.next/cache(/|\z)},
      %r{(?:\A|/)\.angular/cache(/|\z)},
      %r{(?:\A|/)\.vite(/|\z)},
      %r{\.gem\z},
      %r{(?:\A|/)\.env(?:\..+)?\z},
      %r{(?:\A|/)(?:id_rsa|id_ed25519|.*\.(?:pem|key|p12))\z}i
    ].freeze

    def initialize(root_dir: Dir.pwd)
      @root_dir              = File.expand_path(root_dir)
      @gemspec_path          = nil
      @inline_spec_block     = nil
      @out_dir               = "pkg"
      @cache_dir             = ".rtf-cache"
      @incremental           = true
      @reproducible          = true
      @source_date_epoch     = parse_epoch(ENV["SOURCE_DATE_EPOCH"])
      @parallel_jobs         = [Etc.nprocessors, 1].max
      @strict_security       = true
      @auto_detect_resources = true
      @skip_assets           = false
      @skip_extensions       = false
      @write_staged_assets   = false
      @quiet                 = false
      @verbose               = false
      @asset_helper_module   = nil
      @asset_helper_path     = nil
      @resources             = []
      @budgets               = []
      @plugins               = []
      @extra_excludes        = []
      @extra_includes        = []
      @hooks                 = {
        before_resolve: [],
        transform: [],
        generate_bundle: [],
        after_package: []
      }
    end

    # DSL setter/getter methods so scripts can write `pkg.gemspec "foo.gemspec"` cleanly.
    def gemspec(path = nil)
      @gemspec_path = path if path
      @gemspec_path
    end

    # Define a Gem::Specification inline in a standalone compiler script without a .gemspec file.
    def spec(&block)
      raise ConfigError, "Config#spec requires a block" unless block_given?

      @inline_spec_block = block
    end

    def output_dir(dir)
      @out_dir = dir
    end

    def cache(enabled = true, dir: nil)
      @incremental = enabled
      @cache_dir = dir if dir
    end

    def parallel(jobs)
      @parallel_jobs = [jobs.to_i, 1].max
    end

    def exclude(*patterns)
      @extra_excludes.concat(patterns.flatten)
    end

    def include_files(*globs)
      @extra_includes.concat(globs.flatten)
    end

    # Register a Vite frontend resource pipeline.
    def vite(root: ".", out_dir: "dist", mount_to: "public/vite", build_command: nil, auto_build: false, **opts)
      @resources << {
        type: :vite,
        root: root,
        out_dir: out_dir,
        mount_to: mount_to,
        build_command: build_command,
        auto_build: auto_build,
        options: opts
      }
    end

    # Register a Next.js frontend resource pipeline (static export or .next/static bundles).
    def nextjs(root: ".", mode: :auto, out_dir: nil, mount_to: "public/nextjs", build_command: nil, auto_build: false, **opts)
      @resources << {
        type: :nextjs,
        root: root,
        mode: mode,
        out_dir: out_dir,
        mount_to: mount_to,
        build_command: build_command,
        auto_build: auto_build,
        options: opts
      }
    end

    # Register an Angular Architect workspace resource pipeline.
    def angular(root: ".", project: nil, out_dir: nil, mount_to: "public/angular", build_command: nil, auto_build: false, **opts)
      @resources << {
        type: :angular,
        root: root,
        project: project,
        out_dir: out_dir,
        mount_to: mount_to,
        build_command: build_command,
        auto_build: auto_build,
        options: opts
      }
    end

    # Configure embedded Ruby runtime helper generation for staged frontend manifests.
    def generate_asset_helper(module_name:, path:)
      @asset_helper_module = module_name
      @asset_helper_path   = path
    end

    # Register Angular-inspired package and asset size budgets.
    def budget(max_compressed_kb: nil, max_unpacked_kb: nil, max_entry_kb: nil, warn_ratio: 0.85)
      @budgets << {
        max_compressed_kb: max_compressed_kb,
        max_unpacked_kb: max_unpacked_kb,
        max_entry_kb: max_entry_kb,
        warn_ratio: warn_ratio
      }
    end

    # Register a plugin object responding to lifecycle hooks.
    def use(plugin)
      raise ConfigError, "Plugin cannot be nil" if plugin.nil?

      @plugins << plugin
    end

    # Pre-compresses staged web assets into `.gz` sidecars for zero-CPU serving via `RubyToFaster::Middleware`.
    def precompress_assets(min_bytes: 256)
      use(Plugins::Precompress.new(min_bytes: min_bytes))
    end

    # Compiles every packaged `.rb` file via `RubyVM::InstructionSequence` to catch syntax errors at build time.
    def validate_ruby_syntax(normalize_newlines: true)
      use(Plugins::RubyValidator.new(normalize_newlines: normalize_newlines))
    end

    # Generates a CycloneDX 1.5 Software Bill of Materials (`sbom.cdx.json`) across Ruby + npm dependencies.
    def generate_sbom(embed_in_gem: false, output_filename: nil)
      use(Plugins::SBOM.new(embed_in_gem: embed_in_gem, output_filename: output_filename))
    end

    # Emits `.sha256` and SLSA v1 `.provenance.json` attestations alongside built `.gem` files.
    def generate_provenance
      use(Plugins::Provenance.new)
    end

    def before_resolve(&block)
      @hooks[:before_resolve] << block if block
    end

    def transform(&block)
      @hooks[:transform] << block if block
    end

    def generate_bundle(&block)
      @hooks[:generate_bundle] << block if block
    end

    def after_package(&block)
      @hooks[:after_package] << block if block
    end

    def resolved_out_dir
      File.expand_path(@out_dir, @root_dir)
    end

    def resolved_cache_dir
      File.expand_path(@cache_dir, @root_dir)
    end

    private

    def parse_epoch(raw)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Integer(raw.to_s.strip, 10)
    rescue ArgumentError
      raise ConfigError, "Invalid SOURCE_DATE_EPOCH value: #{raw.inspect}"
    end
  end
end
