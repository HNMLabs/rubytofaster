# Monorepo Workspaces & DAG Builds

Modern Ruby ecosystems (such as modular SDKs, plugin suites, and Rails Engine monorepos) frequently maintain multiple `.gemspec` packages in a single repository (`gems/*`, `packages/*`, `plugins/*`, `apps/*`).

Inspired by **Turborepo**, **Nx**, and **Angular Workspaces**, `RubyToFaster::Workspace` (`rtf workspace`) executes **topological dependency graph builds** across multi-gem repositories.

---

## How Topological Wave Execution Works

1. **Discovery:** Scans workspace globs (default: `gems/*`, `packages/*`, `plugins/*`, `apps/*`) for directories containing `gem.build.rb` or `*.gemspec`.
2. **Graph Construction:** Inspects each `Gem::Specification#dependencies` list to map internal edges between sibling workspace gems.
3. **Cycle Detection:** Runs Kahn's algorithm—if `gem_a` depends on `gem_b` and `gem_b` depends on `gem_a`, aborts immediately with a descriptive `RubyToFaster::ConfigError`.
4. **Parallel Wave Compilation:** Groups gems with zero unmet dependencies into waves and builds every gem inside a wave **concurrently across CPU threads**, sharing `.rtf-cache` Merkle hits per package.

---

## CLI Usage

```bash
# Discover and build all workspace gems in topological waves
rtf workspace

# Specify custom directory globs
rtf workspace --patterns "core/*,integrations/*"

# Force cold rebuild across all workspace gems and output JSON telemetry
rtf workspace --no-cache --json
```

---

## Ruby Script API

```ruby
require "rubytofaster"

ws = RubyToFaster.workspace(
  root_dir: __dir__,
  patterns: ["packages/*"],
  parallel_jobs: 8,
  incremental: true
)

puts "Built #{ws.results.size} gems across #{ws.waves.size} waves in #{ws.total_ms}ms (#{ws.cache_hits} cache hits)"
```
