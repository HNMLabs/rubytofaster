# Security Policy

HNM Labs takes the security and supply-chain integrity of **RubyToFaster** seriously. Because `rubytofaster` compiles, packages, and serves code and frontend assets inside distributable `.gem` archives, defense-in-depth controls and software supply-chain attestations are built directly into the compiler and runtime middleware.

---

## Supported Versions

The following release series currently receive security updates and patches:

| Version | Supported          | Ruby Requirement |
| ------- | ------------------ | ---------------- |
| `0.2.x` | :white_check_mark: | Ruby `>= 3.0.0`  |
| `0.1.x` | :white_check_mark: | Ruby `>= 3.0.0`  |
| `< 0.1` | :x:                | N/A              |

---

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions, or pull requests.**

Please report suspected vulnerabilities privately through one of the following channels:

1. **GitHub Private Vulnerability Reporting (Preferred):**
   Submit a confidential advisory directly at:
   https://github.com/HNMLabs/rubytofaster/security/advisories/new
2. **Email:**
   Send a detailed report to **security@hnmlabs.dev** with the subject line `[SECURITY] rubytofaster: <brief summary>`.

### What to Include in Your Report

- Affected `rubytofaster` version (`rtf -v`), Ruby version (`ruby -v`), and OS platform.
- A minimal proof-of-concept (`gem.build.rb`, `.gemspec`, HTTP request to `RubyToFaster::Middleware`, or directory layout) reproducing the issue.
- Impact assessment (e.g., arbitrary file inclusion, path traversal, command injection, checksum bypass, cache poisoning).
- Suggested remediation or patch, if available.

### Response Timeline & Coordinated Disclosure

| Stage | Target SLA |
| :--- | :--- |
| Initial acknowledgement | Within **48 hours** |
| Triage & severity assessment | Within **5 business days** |
| Fix development & release (Critical/High) | Within **14 days** |
| Public advisory & credit | Coordinated upon patch release |

---

## Built-in Security & Supply-Chain Controls

### 1. Path Traversal & Tar-Slip Protection (Build & Runtime)
- **Build-time (`RubyToFaster::FileResolver`):** Every relative path from `.gemspec`, `include_files`, or frontend output directories passes through `sanitize_relative_path!`. Paths containing `..` segments, leading slashes (`/`), backslashes, or NUL bytes (`\0`), or escaping `root_dir`, abort immediately with `RubyToFaster::SecurityError`.
- **Runtime (`RubyToFaster::Middleware`):** Incoming `PATH_INFO` requests containing `..`, `\`, or NUL bytes return `403 Forbidden`, canonical paths are verified to reside strictly inside the configured asset root, symlinks are never served, and `X-Content-Type-Options: nosniff` is always emitted.

### 2. Symlink Escape Prevention
- Source symlinks are canonicalized via `File.realpath` and verified to remain strictly inside the canonical project root; dangling or escaping symlinks raise `RubyToFaster::SecurityError`.
- Symlinks inside compiled frontend build directories (`dist/`, `.next/`, `out/`) are unconditionally rejected to prevent compromised npm postinstall scripts from symlinking host secrets into published `.gem` archives.

### 3. Shell-Injection-Free Subprocess Execution
When invoking frontend bundlers (`vite`, `next`, `ng`) or native extension toolchains (`ruby extconf.rb`, `make`), `RubyToFaster` passes argument arrays directly to `Open3.capture3(env, *argv, chdir: ...)` without invoking `/bin/sh -c`. Raw shell command strings passed to `build_command:` are explicitly rejected with `RubyToFaster::ConfigError`.

### 4. Automatic Secret & Credential Tree-Shaking
`RubyToFaster` automatically prunes and blocks sensitive files from entering `data.tar.gz`, including:
- Environment files (`.env`, `.env.local`, `.env.production`, etc.)
- Private keys and certificates (`*.pem`, `*.key`, `*.p12`, `id_rsa`, `id_ed25519`)
- Encrypted app credentials (`credentials.yml.enc`)
- Bundler caches (`node_modules/`, `.next/cache/`, `.angular/cache/`, `.rtf-cache/`)

### 5. CycloneDX 1.5 SBOM & SLSA v1 Build Provenance
- **CycloneDX 1.5 SBOM (`rtf build --sbom` / `pkg.generate_sbom`):** Emits `.sbom.cdx.json` cataloging both Ruby gem runtime dependencies (`pkg:gem/...`) and frontend `package.json` dependencies (`pkg:npm/...`) alongside SHA-256/SHA-512 package hashes.
- **SLSA v1 Provenance (`rtf build --provenance` / `pkg.generate_provenance`):** Emits `.sha256` digests and in-toto Statement v1 / SLSA Provenance v1 JSON attestations (`.provenance.json`).
- **Deterministic Reproducible Builds (`SOURCE_DATE_EPOCH`):** Sorted tar entries, normalized POSIX modes (`0644` / `0755`), and pinned gzip `mtime` headers allow independent third parties to reproduce identical SHA-256 `.gem` hashes from source.
