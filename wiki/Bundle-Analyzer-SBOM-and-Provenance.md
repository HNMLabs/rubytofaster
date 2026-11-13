# Bundle Analyzer, SBOM & SLSA Provenance

`RubyToFaster` brings modern frontend bundle visualization (`@next/bundle-analyzer` / `rollup-plugin-visualizer`) and enterprise software supply-chain attestations (**CycloneDX 1.5** & **SLSA v1**) natively to Ruby gems.

---

## 1. Interactive HTML Bundle Analyzer (`rtf analyze`)

Inspect unpacked vs gzipped byte weights grouped across Ruby `lib/`, Vite chunks, Next.js bundles, Angular assets, RBS signatures, native extensions, and `.gz` sidecars:

```bash
# Terminal summary + self-contained interactive HTML treemap report
rtf analyze pkg/my_gem-0.2.0.gem --html pkg/bundle-report.html
```

The generated `bundle-report.html` has **zero external CDN or JavaScript dependencies**, making it safe to archive as a CI build artifact or attach to GitHub Releases.

---

## 2. CycloneDX 1.5 Software Bill of Materials (`--sbom`)

Generate a standardized **CycloneDX 1.5** JSON SBOM cataloging **both** Ruby runtime gem dependencies (`pkg:gem/...`) and frontend workspace `package.json` dependencies (`pkg:npm/...`), complete with SHA-256 and SHA-512 package hashes:

```bash
rtf build --sbom
# Emits pkg/<name>-<version>.gem.sbom.cdx.json
```

Or enable it permanently inside `gem.build.rb` (optionally embedding `sbom.cdx.json` inside the `.gem` itself):

```ruby
RubyToFaster.build do |pkg|
  pkg.gemspec "my_gem.gemspec"
  pkg.generate_sbom(embed_in_gem: true)
end
```

---

## 3. SLSA v1 Build Provenance & Checksums (`--provenance`)

Emit `.sha256` checksum files alongside in-toto Statement v1 / **SLSA Provenance v1** attestations (`.provenance.json`) recording subject digests, Merkle cache key, builder environment, and frontend resource metadata:

```bash
rtf build --provenance
# Emits:
#   pkg/<name>-<version>.gem.sha256
#   pkg/<name>-<version>.gem.provenance.json
```
