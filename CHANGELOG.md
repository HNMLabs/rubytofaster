# Changelog

All notable changes to **RubyToFaster** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
