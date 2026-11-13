# Welcome to the RubyToFaster Wiki

**RubyToFaster (`rtf`) v0.2** is a minimalist, zero-dependency, script-first build system for Ruby gems. It executes the package compiler directly as a lightweight Ruby script (`gem.build.rb`) while integrating frontend resource pipelines, HMR + Rack static serving, topological monorepo builds, interactive HTML bundle analyzers, and supply-chain provenance inspired by **Angular**, **Vite**, and **Next.js**.

---

## Core Highlights

- **46x Faster Incremental Builds:** SHA-256 Merkle caching (`.rtf-cache/`) restores unchanged `.gem` packages in **~4.0ms** (compared to ~188ms for `gem build`).
- **Script-First Minimalist Execution:** Build via `./gem.build.rb`, `require "rubytofaster/autorun"`, or inline `pkg.spec` blocks with **zero runtime gem dependencies** and shipped **RBS type signatures**.
- **End-to-End Angular, Vite & Next.js Integration:** Stage compiled bundles in-memory, pre-compress `.gz` sidecars, inject live `@vite/client` HMR tags in development, and serve immutable assets in production via `RubyToFaster::Middleware`.
- **Topological Monorepo Workspaces (`rtf workspace`):** Compile multi-gem repositories in parallel dependency waves.
- **Bundle Treemap & Supply-Chain Security:** Generate zero-CDN HTML treemap reports (`rtf analyze --html`), **CycloneDX 1.5 SBOMs** (`--sbom`), and **SLSA v1 provenance** (`--provenance`).

---

## Complete Documentation Index

| Guide | Summary |
| :--- | :--- |
| **[[Getting Started\|Getting-Started]]** | Install `rubytofaster`, scaffold gems with `rtf new --fullstack`, and run your first script build. |
| **[[Architecture & Compiler Pipeline\|Architecture-and-Compiler-Pipeline]]** | Inside the in-memory deterministic packager, Merkle cache, `RubyVM` syntax verifier, and parallel C/Rust builder. |
| **[[Frontend Resources: Vite, Next.js & Angular\|Frontend-Resources-Vite-Nextjs-Angular]]** | Configure Vite, Next.js (`out/` & `.next/static`), and Angular (`angular.json`) resource adapters. |
| **[[Rack Middleware & HMR Dev Mode\|Rack-Middleware-and-HMR-Dev-Mode]]** | Serve `.gz` precompressed assets with `Cache-Control: immutable` in production and live HMR in development. |
| **[[Monorepo Workspaces & DAG Builds\|Monorepo-Workspaces-and-DAG-Builds]]** | Build multi-gem repositories in parallel topological waves (`rtf workspace`). |
| **[[Bundle Analyzer, SBOM & SLSA Provenance\|Bundle-Analyzer-SBOM-and-Provenance]]** | Visualize `.gem` composition (`rtf analyze --html`) and emit CycloneDX 1.5 SBOMs & SLSA attestations. |
| **[[CLI & Script API Reference\|CLI-and-Script-API-Reference]]** | Complete reference for `RubyToFaster::Config`, built-in `Plugins`, `Middleware`, and `rtf` CLI flags. |
| **[[Security & Reproducible Builds\|Security-and-Reproducible-Builds]]** | `SOURCE_DATE_EPOCH` bit-for-bit reproducibility, path/symlink jails, and secret tree-shaking. |
| **[[Troubleshooting & FAQ\|Troubleshooting-and-FAQ]]** | Common questions, CI caching recipes, and diagnostics. |
