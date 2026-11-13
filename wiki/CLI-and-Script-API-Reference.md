# CLI & Script API Reference

## CLI Commands (`rtf` / `rubytofaster`)

| Command | Description |
| :--- | :--- |
| `rtf [build] [target]` | Compiles `.gem` from `gem.build.rb`, `*.gemspec`, or explicit target (`--no-cache`, `--sbom`, `--provenance`, `-V`, `--json`). |
| `rtf new <gem_name>` | Scaffolds a modern zero-Rake gem (`--vite`, `--nextjs`, `--angular`, `--fullstack`, `-d DIR`). |
| `rtf init [flags]` | Generates an executable `gem.build.rb` in an existing repo (`--vite`, `--nextjs`, `--angular`, `--force`). |
| `rtf inspect <file.gem>` | Verifies SHA-256/SHA-512 checksums and lists tar entries & frontend manifests (`--json`). |
| `rtf analyze <file.gem>` | Breaks down unpacked vs gzipped composition and writes interactive HTML treemaps (`--html FILE`, `--json`). |
| `rtf workspace` | Builds multi-gem monorepos in parallel topological dependency waves (`--patterns`, `--no-cache`, `--json`). |
| `rtf bench` | Benchmarks `gem build` CLI vs `Gem::Package.build` vs `RubyToFaster` cold & warm cache (`-n N`, `--json`). |
| `rtf watch [target]` | Watches source files and runs incremental builds (`-i SECONDS`). |
| `rtf doctor` | Prints JSON diagnostics for Ruby, RubyGems, gemspecs, and detected frontend configs. |
| `rtf clean` | Deletes `.rtf-cache/` and `pkg/`. |
| `rtf version` | Prints `rubytofaster` version (`-v`, `--version`). |

---

## Ruby Script DSL (`RubyToFaster.build`)

```ruby
result = RubyToFaster.build(root_dir: __dir__, report: true) do |pkg|
  # 1. Gem specification source
  pkg.gemspec "my_gem.gemspec"
  # OR inline: pkg.spec { |s| ... }

  # 2. Output, Caching & Reproducibility
  pkg.output_dir "pkg"
  pkg.cache true, dir: ".rtf-cache"
  pkg.reproducible = true
  pkg.source_date_epoch = 1_700_000_000
  pkg.parallel 4

  # 3. Built-in Standard Plugins
  pkg.validate_ruby_syntax(normalize_newlines: true)
  pkg.precompress_assets(min_bytes: 256)
  pkg.generate_sbom(embed_in_gem: false)
  pkg.generate_provenance

  # 4. Frontend Resource Adapters
  pkg.vite    root: "frontend", out_dir: "dist", mount_to: "public/vite"
  pkg.nextjs  root: "portal",   mode: :auto,     mount_to: "public/nextjs"
  pkg.angular root: "admin",    project: "app",  mount_to: "public/angular"
  pkg.generate_asset_helper module_name: "MyGem::Assets", path: "lib/my_gem/assets.rb"

  # 5. Angular-Style Size Budgets
  pkg.budget max_compressed_kb: 512, max_unpacked_kb: 2048, max_entry_kb: 256

  # 6. Custom Plugins & Inline Hooks
  pkg.use MyCustomPlugin.new
  pkg.before_resolve  { |cfg| }
  pkg.transform       { |gem_path, raw_bytes| nil }
  pkg.generate_bundle { |entries_hash, cfg| }
  pkg.after_package   { |build_result| }
end
```
