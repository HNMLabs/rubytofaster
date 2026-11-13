# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "rubygems/package"
require "stringio"
require "zlib"

module RubyToFaster
  # `@next/bundle-analyzer` & `rollup-plugin-visualizer` inspired bundle analyzer for `.gem` packages.
  # Breaks down unpacked vs gzipped weights by category and renders a self-contained HTML treemap dashboard.
  class Analyzer
    CATEGORIES = {
      vite_assets:       { label: "Vite Assets",        color: "#8b5cf6" },
      nextjs_assets:     { label: "Next.js Bundles",    color: "#3b82f6" },
      angular_assets:    { label: "Angular Bundles",    color: "#ef4444" },
      precompressed:     { label: "Precompressed (.gz)", color: "#14b8a6" },
      ruby_lib:          { label: "Ruby Code (lib/)",   color: "#f59e0b" },
      type_signatures:   { label: "RBS Signatures",     color: "#06b6d4" },
      native_extensions: { label: "Native Extensions",  color: "#ec4899" },
      executables:       { label: "CLI Executables",    color: "#10b981" },
      docs_and_meta:     { label: "Docs & Metadata",    color: "#64748b" }
    }.freeze

    def self.analyze(gem_path)
      new(gem_path).analyze
    end

    def initialize(gem_path)
      raise ConfigError, "Gem file not found: #{gem_path}" unless File.file?(gem_path)

      @gem_path = File.expand_path(gem_path)
    end

    def analyze
      pkg = Gem::Package.new(@gem_path)
      pkg.verify
      spec = pkg.spec

      items = []
      unpacked_total = 0
      gzip_total = 0

      File.open(@gem_path, "rb") do |outer_io|
        Gem::Package::TarReader.new(outer_io) do |outer_tar|
          outer_tar.each do |outer_entry|
            next unless outer_entry.full_name == "data.tar.gz"

            Zlib::GzipReader.wrap(outer_entry) do |gz_io|
              Gem::Package::TarReader.new(gz_io) do |data_tar|
                data_tar.each do |entry|
                  bytes = entry.read || "".b
                  raw_size = bytes.bytesize
                  gz_size  = entry.full_name.end_with?(".gz") ? raw_size : estimate_gzip_size(bytes)
                  cat      = classify(entry.full_name, spec)

                  unpacked_total += raw_size
                  gzip_total     += gz_size

                  items << {
                    path: entry.full_name,
                    category: cat,
                    category_label: CATEGORIES[cat][:label],
                    unpacked_bytes: raw_size,
                    gzip_bytes: gz_size,
                    sha256: Digest::SHA256.hexdigest(bytes)
                  }
                end
              end
            end
          end
        end
      end

      items.sort_by! { |i| -i[:unpacked_bytes] }
      items.each do |i|
        i[:share_pct] = unpacked_total.positive? ? ((i[:unpacked_bytes].to_f / unpacked_total) * 100.0).round(2) : 0.0
      end

      by_category = CATEGORIES.each_with_object({}) do |(key, meta), acc|
        matched = items.select { |i| i[:category] == key }
        next if matched.empty?

        cat_unpacked = matched.sum { |i| i[:unpacked_bytes] }
        cat_gzip     = matched.sum { |i| i[:gzip_bytes] }
        acc[key] = {
          label: meta[:label],
          color: meta[:color],
          file_count: matched.size,
          unpacked_bytes: cat_unpacked,
          gzip_bytes: cat_gzip,
          share_pct: unpacked_total.positive? ? ((cat_unpacked.to_f / unpacked_total) * 100.0).round(2) : 0.0
        }
      end

      {
        gem_name: spec.name,
        gem_version: spec.version.to_s,
        gem_file: @gem_path,
        archive_bytes: File.size(@gem_path),
        unpacked_bytes: unpacked_total,
        estimated_gzip_sum_bytes: gzip_total,
        compression_ratio: unpacked_total.positive? ? (File.size(@gem_path).to_f / unpacked_total).round(3) : 1.0,
        file_count: items.size,
        categories: by_category,
        largest_files: items.first(15),
        files: items
      }
    end

    def write_html_report(report_data, html_path)
      FileUtils.mkdir_p(File.dirname(File.expand_path(html_path)))
      json_payload = JSON.generate(report_data).gsub("</", "<\\/")
      title = CGI.escapeHTML("#{report_data[:gem_name]} v#{report_data[:gem_version]} — Bundle Analysis")

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{title}</title>
          <style>
            :root { --bg: #0f172a; --panel: #1e293b; --border: #334155; --text: #f8fafc; --muted: #94a3b8; }
            * { box-sizing: border-box; }
            body { margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); padding: 24px; }
            .wrap { max-width: 1160px; margin: 0 auto; }
            header { display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 12px; margin-bottom: 24px; }
            h1 { margin: 0; font-size: 1.5rem; letter-spacing: -0.02em; }
            .badge { background: #334155; color: #38bdf8; padding: 4px 10px; border-radius: 999px; font-size: 0.8rem; font-weight: 600; }
            .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; margin-bottom: 24px; }
            .card { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
            .kpi-label { font-size: 0.78rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
            .kpi-val { font-size: 1.55rem; font-weight: 700; margin-top: 6px; font-variant-numeric: tabular-nums; }
            .bar { display: flex; height: 28px; border-radius: 8px; overflow: hidden; margin: 12px 0 16px; background: #0b1120; }
            .legend { display: flex; flex-wrap: wrap; gap: 14px; font-size: 0.85rem; }
            .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
            .treemap { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 14px; }
            .tile { border-radius: 8px; padding: 10px; min-width: 120px; flex-grow: 1; color: #fff; background: #334155; overflow: hidden; }
            .tile-path { font-size: 0.78rem; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .tile-meta { font-size: 0.72rem; opacity: 0.88; margin-top: 4px; font-variant-numeric: tabular-nums; }
            table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 0.86rem; font-variant-numeric: tabular-nums; }
            th, td { text-align: left; padding: 9px 10px; border-bottom: 1px solid var(--border); }
            th { color: var(--muted); font-weight: 600; }
            input[type="search"] { width: 100%; padding: 9px 12px; border-radius: 8px; border: 1px solid var(--border); background: #0f172a; color: var(--text); margin-bottom: 10px; }
          </style>
        </head>
        <body>
          <div class="wrap">
            <header>
              <h1>RubyToFaster Bundle Analyzer — <span id="gemTitle"></span></h1>
              <span class="badge">Generated by RubyToFaster v#{RubyToFaster::VERSION}</span>
            </header>
            <div class="kpis" id="kpis"></div>
            <div class="card" style="margin-bottom:24px">
              <div class="kpi-label">Payload Composition by Category</div>
              <div class="bar" id="compBar"></div>
              <div class="legend" id="compLegend"></div>
              <div class="treemap" id="treemap"></div>
            </div>
            <div class="card">
              <div class="kpi-label" style="margin-bottom:10px">All Packaged Entries</div>
              <input type="search" id="filterInput" placeholder="Filter files by path or category (e.g. vite, lib/, .js)...">
              <table>
                <thead><tr><th>Path</th><th>Category</th><th>Unpacked</th><th>Gzip</th><th>Share</th></tr></thead>
                <tbody id="fileRows"></tbody>
              </table>
            </div>
          </div>
          <script>
            const DATA = #{json_payload};
            const fmtKB = (b) => (b / 1024).toFixed(2) + " KB";
            document.getElementById("gemTitle").textContent = DATA.gem_name + " v" + DATA.gem_version;
            const kpis = [
              ["Compressed .gem", fmtKB(DATA.archive_bytes)],
              ["Unpacked Payload", fmtKB(DATA.unpacked_bytes)],
              ["Compression Ratio", (DATA.compression_ratio * 100).toFixed(1) + "%"],
              ["Packaged Files", String(DATA.file_count)]
            ];
            document.getElementById("kpis").innerHTML = kpis.map(([l, v]) =>
              `<div class="card"><div class="kpi-label">${l}</div><div class="kpi-val">${v}</div></div>`
            ).join("");

            const cats = Object.values(DATA.categories);
            document.getElementById("compBar").innerHTML = cats.map(c =>
              `<div style="width:${Math.max(c.share_pct, 0.8)}%;background:${c.color}" title="${c.label}: ${fmtKB(c.unpacked_bytes)} (${c.share_pct}%)"></div>`
            ).join("");
            document.getElementById("compLegend").innerHTML = cats.map(c =>
              `<span><i class="dot" style="background:${c.color}"></i>${c.label}: <strong>${fmtKB(c.unpacked_bytes)}</strong> (${c.share_pct}%)</span>`
            ).join("");

            const catColors = {};
            Object.entries(DATA.categories).forEach(([k, v]) => { catColors[k] = v.color; });
            document.getElementById("treemap").innerHTML = DATA.largest_files.map(f =>
              `<div class="tile" style="flex-basis:${Math.max(f.share_pct * 3.2, 14)}%;background:${catColors[f.category] || '#475569'}">
                 <div class="tile-path" title="${f.path}">${f.path}</div>
                 <div class="tile-meta">${fmtKB(f.unpacked_bytes)} · gzip ${fmtKB(f.gzip_bytes)} (${f.share_pct}%)</div>
               </div>`
            ).join("");

            const tbody = document.getElementById("fileRows");
            const renderTable = (q) => {
              const needle = q.toLowerCase();
              const rows = DATA.files.filter(f => !needle || f.path.toLowerCase().includes(needle) || f.category_label.toLowerCase().includes(needle));
              tbody.innerHTML = rows.map(f =>
                `<tr><td><code>${f.path}</code></td><td>${f.category_label}</td><td>${fmtKB(f.unpacked_bytes)}</td><td>${fmtKB(f.gzip_bytes)}</td><td>${f.share_pct}%</td></tr>`
              ).join("");
            };
            renderTable("");
            document.getElementById("filterInput").addEventListener("input", (e) => renderTable(e.target.value));
          </script>
        </body>
        </html>
      HTML

      File.write(html_path, html)
      File.expand_path(html_path)
    end

    private

    def classify(path, spec)
      return :precompressed     if path.end_with?(".gz")
      return :vite_assets       if path.include?("/vite/") || path.start_with?("public/vite/")
      return :nextjs_assets     if path.include?("_next/") || path.include?("/nextjs/")
      return :angular_assets    if path.include?("/angular/") || path.start_with?("public/angular/")
      return :type_signatures   if path.start_with?("sig/") || path.end_with?(".rbs")
      return :native_extensions if path.start_with?("ext/") || path.match?(/\.(?:c|cc|cpp|h|rs|so|bundle)\z/)

      bindir = "#{spec.bindir || 'exe'}/"
      return :executables       if path.start_with?(bindir) || path.start_with?("bin/")
      return :ruby_lib          if path.start_with?("lib/") || path.end_with?(".rb")

      :docs_and_meta
    end

    def estimate_gzip_size(bytes)
      return 0 if bytes.empty?

      buf = StringIO.new("".b)
      gz = Zlib::GzipWriter.new(buf, Zlib::BEST_COMPRESSION)
      gz.write(bytes)
      gz.close
      buf.string.bytesize
    end
  end
end
