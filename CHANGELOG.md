# Changelog

All notable changes to **RubyToFaster** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-15

### Added
- **Zero-Dependency Animated GIF89a Speed Renderer (`RubyToFaster::GifRenderer`, `rtf bench --gif`)**: Pure-Ruby GIF89a encoder (variable-width 9..12-bit LZW compressor, transparent inter-frame delta compression, `NETSCAPE2.0` looping, and embedded JSON provenance comment blocks) rendering real measured hardware speed scores into an `880x460` dark-mode animated dashboard.
- **Statistical Benchmark Telemetry (`RubyToFaster::Benchmarker`, `RubyToFaster.bench`)**: Added warmup iterations (`-w` / `--warmup`), GC isolation between runs, median/stddev/throughput (`ops/sec`) metrics, git SHA metadata, and `--gif`, `--json-out`, and `--markdown-out` exporters.
- **Automated GitHub Benchmark GIF Pipeline (`.github/workflows/benchmarks.yml`)**: Measures real runner latencies on GitHub Actions, publishes Markdown tables to `$GITHUB_STEP_SUMMARY`, uploads GIF/JSON artifacts, and keeps `assets/benchmarks.gif` updated.
- **Configurable Archive Compression (`Config#compression_level`)**: Defaults to `Zlib::DEFAULT_COMPRESSION` with full support for `Zlib::BEST_COMPRESSION`.

### Fixed
- **Parallel Workspace Thread Safety**: Replaced process-global `@pending_script_capture` and unsynchronized `Dir.chdir` / `SOURCE_DATE_EPOCH` mutations with thread-local capture state, `RubyToFaster.with_chdir` monitor synchronization, `base:` globbing, and `Packager::EPOCH_MUTEX`.
- **Merkle Cache Invalidation Accuracy**: Included plugin fingerprints, `compression_level`, and full `Gem::Specification` metadata (`authors`, `email`, `homepage`, `require_paths`, `extensions`, `post_install_message`) in `Cache#compute_key`, and ran dynamic inline transform closures prior to cache lookup.
- **`autorun` Multi-Load Re-Entrancy**: Fixed `require "rubytofaster/autorun"` becoming a no-op across subsequent `rtf watch` cycles and multi-gem `Workspace` builds, and resolved `root_dir` from the invoking script path.
- **Parent-Directory Symlink Jail Hardening**: Blocked intermediate directory symlink escapes across `FileResolver`, `Resources::Base`, and `Middleware`.
- **Rack Middleware HTTP & Security Fixes**: Added percent-decoding before path-traversal/null-byte checks, `Accept-Encoding: gzip;q=0` handling, distinct `-gz` weak ETags, and multi-tag `If-None-Match` matching with `Vary: Accept-Encoding` on `304` responses.
- **SBOM Nested `--out-dir` & Subdirectory Gemspec CLI**: Fixed `Plugins::SBOM` `package.json` discovery when `--out-dir` is deeply nested and fixed `rtf build path/to/sub.gemspec` root directory resolution.

### Performance
- **Sub-Millisecond Incremental Merkle Cache Hits (~0.9ms, >150x faster than `gem build`)**: Added stat-indexed SHA-256 file digest memoization, directory-level `realpath` memoization, in-memory outer `.gem` tar assembly, and fingerprinted plugin short-circuiting on verified cache hits.

## [0.2.0] - 2026-11-13

### Added
- **Zero-Dependency Rack Asset Middleware (`RubyToFaster::Middleware`)**: Production static & SPA middleware for Vite, Next.js (`/_next/static` & clean HTML export routes), and Angular (`browser/` SPA fallback) with pre-compressed `.gz` negotiation, `ETag` (`304 Not Modified`), `Cache-Control: immutable` on hashed bundles, `X-Content-Type-Options: nosniff`, and `403` path-traversal defense.
- **Live Dev-Server HMR Integration (`AssetManifest#html_tags`)**: Automatic `@vite/client` and live dev-server entrypoint tag injection when `RTF_DEV_SERVER` (or `dev_server:`) is set during local development.
- **Topological Monorepo Workspace Runner (`RubyToFaster::Workspace`, `rtf workspace`)**: Turborepo/Nx/Angular-inspired multi-gem dependency DAG discovery, cycle detection, and parallel wave execution across CPU cores.
- **Interactive Bundle Analyzer (`RubyToFaster::Analyzer`, `rtf analyze --html`)**: `@next/bundle-analyzer`-style `.gem` payload categorization (Ruby `lib/`, Vite, Next.js, Angular, RBS, `.gz`) and self-contained zero-CDN HTML treemap report generator.
- **Standard Built-in Plugins (`RubyToFaster::Plugins`)**:
  - `Plugins::Precompress` (`pkg.precompress_assets`): Deterministic `.gz` sidecar generation at build time.
  - `Plugins::RubyValidator` (`pkg.validate_ruby_syntax`): Compile-time `RubyVM::InstructionSequence` syntax verification and CRLF normalization.
  - `Plugins::SBOM` (`pkg.generate_sbom` / `--sbom`): CycloneDX 1.5 JSON Software Bill of Materials across Ruby gemspec and frontend `package.json` dependencies.
  - `Plugins::Provenance` (`pkg.generate_provenance` / `--provenance`): `.sha256` and in-toto / SLSA v1 `.provenance.json` build attestations.
- **Full-Stack Gem Scaffolder (`RubyToFaster::Scaffolder`, `rtf new`)**: Scaffolds modern zero-Rake Ruby gems with `gem.build.rb`, RBS signatures, tests, and optional `--vite`, `--nextjs`, `--angular`, or `--fullstack` workspaces.
- **Built-in Benchmark Harness (`RubyToFaster::Benchmarker`, `rtf bench`)**: Measures `gem build` CLI vs `Gem::Package.build` vs `RubyToFaster` cold & warm Merkle cache hits (~46x speedup).
- **RBS Static Type Signatures (`sig/rubytofaster.rbs`)**: Shipped inside the gem package.
- **Automated GitHub Release Workflow (`.github/workflows/release.yml`)**: Publishes deterministic `.gem`, CycloneDX SBOM, SLSA provenance, and HTML bundle treemap on `v*` tags.

## [0.1.0] - 2026-11-13

### Added
- Initial release of `RubyToFaster` script-first `.gem` compiler, SHA-256 Merkle incremental cache, parallel `extconf.rb` native extension builder, Angular/Vite/Next.js resource adapters, `AssetManifest` Ruby helper codegen, bundle size budgets, plugin runner, and `rtf` CLI.
