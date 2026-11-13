# frozen_string_literal: true

require "digest"

module RubyToFaster
  # Zero-dependency Rack 2.x/3.x compatible static & SPA asset middleware for gems shipping
  # Vite, Next.js, or Angular resources. Supports pre-compressed `.gz` negotiation, `ETag`
  # conditional requests, immutable cache headers on hashed chunks, and path-traversal protection.
  class Middleware
    MIME_TYPES = {
      ".html"  => "text/html; charset=utf-8",
      ".js"    => "text/javascript; charset=utf-8",
      ".mjs"   => "text/javascript; charset=utf-8",
      ".css"   => "text/css; charset=utf-8",
      ".json"  => "application/json; charset=utf-8",
      ".svg"   => "image/svg+xml",
      ".png"   => "image/png",
      ".jpg"   => "image/jpeg",
      ".jpeg"  => "image/jpeg",
      ".webp"  => "image/webp",
      ".avif"  => "image/avif",
      ".gif"   => "image/gif",
      ".ico"   => "image/x-icon",
      ".woff"  => "font/woff",
      ".woff2" => "font/woff2",
      ".ttf"   => "font/ttf",
      ".wasm"  => "application/wasm",
      ".txt"   => "text/plain; charset=utf-8",
      ".map"   => "application/json; charset=utf-8"
    }.freeze

    HASHED_ASSET_PATTERN = /(?:-[a-zA-Z0-9_]{6,}\.(?:js|mjs|css|woff2?|png|webp|svg)\z|\A_next\/static\/)/

    def initialize(app, root:, url_prefix: "/", spa_fallback: false, index_file: "index.html")
      @app          = app
      @root         = File.expand_path(root)
      @url_prefix   = normalize_prefix(url_prefix)
      @spa_fallback = spa_fallback
      @index_file   = index_file
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      return @app.call(env) unless method == "GET" || method == "HEAD"

      path_info = env["PATH_INFO"].to_s
      return @app.call(env) unless matches_prefix?(path_info)

      rel_path = strip_prefix(path_info)
      return forbidden_response if unsafe_path?(rel_path)

      resolved = resolve_candidate_file(rel_path)
      if resolved.nil? && @spa_fallback && accepts_html?(env)
        fallback = File.join(@root, @index_file)
        resolved = fallback if safe_file?(fallback)
      end

      return @app.call(env) unless resolved

      serve_file(env, resolved, method == "HEAD")
    end

    private

    def normalize_prefix(prefix)
      cleaned = "/#{prefix.to_s.strip}".gsub(%r{/+}, "/")
      cleaned == "/" ? "/" : cleaned.chomp("/")
    end

    def matches_prefix?(path_info)
      return true if @url_prefix == "/"

      path_info == @url_prefix || path_info.start_with?("#{@url_prefix}/")
    end

    def strip_prefix(path_info)
      raw = @url_prefix == "/" ? path_info : path_info.delete_prefix(@url_prefix)
      raw.sub(%r{\A/+}, "")
    end

    def unsafe_path?(rel_path)
      return true if rel_path.include?("\0") || rel_path.include?("\\")

      rel_path.split("/").include?("..")
    end

    def resolve_candidate_file(rel_path)
      if rel_path.empty?
        idx = File.join(@root, @index_file)
        return idx if safe_file?(idx)

        return nil
      end

      direct = File.join(@root, rel_path)
      return direct if safe_file?(direct)

      # Next.js static export clean route resolution (`/docs` -> `docs.html` or `docs/index.html`)
      html_variant = "#{direct}.html"
      return html_variant if safe_file?(html_variant)

      nested_idx = File.join(direct, @index_file)
      return nested_idx if safe_file?(nested_idx)

      nil
    end

    def safe_file?(full_path)
      expanded = File.expand_path(full_path)
      root_prefix = @root.end_with?("/") ? @root : "#{@root}/"
      return false unless expanded.start_with?(root_prefix)
      return false unless File.file?(expanded) && !File.symlink?(expanded)

      true
    end

    def accepts_html?(env)
      accept = env["HTTP_ACCEPT"].to_s
      accept.empty? || accept.include?("text/html") || accept.include?("*/*")
    end

    def serve_file(env, file_path, head_only)
      rel = file_path.delete_prefix("#{@root}/")
      etag = compute_etag(file_path)

      if env["HTTP_IF_NONE_MATCH"] == etag
        return [304, { "etag" => etag, "cache-control" => cache_control_for(rel) }, []]
      end

      gz_path = "#{file_path}.gz"
      use_gzip = client_accepts_gzip?(env) && safe_file?(gz_path)
      payload_path = use_gzip ? gz_path : file_path

      headers = {
        "content-type"  => MIME_TYPES.fetch(File.extname(file_path).downcase, "application/octet-stream"),
        "cache-control" => cache_control_for(rel),
        "etag"          => etag,
        "vary"          => "Accept-Encoding",
        "x-content-type-options" => "nosniff"
      }
      headers["content-encoding"] = "gzip" if use_gzip

      bytes = File.binread(payload_path)
      headers["content-length"] = bytes.bytesize.to_s

      [200, headers, head_only ? [] : [bytes]]
    end

    def client_accepts_gzip?(env)
      env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip")
    end

    def cache_control_for(rel_path)
      if HASHED_ASSET_PATTERN.match?(rel_path)
        "public, max-age=31536000, immutable"
      else
        "public, max-age=0, must-revalidate"
      end
    end

    def compute_etag(file_path)
      stat = File.stat(file_path)
      %(W/"#{stat.size.to_s(16)}-#{stat.mtime.to_i.to_s(16)}")
    end

    def forbidden_response
      [403, { "content-type" => "text/plain; charset=utf-8" }, ["Forbidden"]]
    end
  end
end
