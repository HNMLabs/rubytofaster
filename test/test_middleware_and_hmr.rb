# frozen_string_literal: true

require "test_helper"
require "zlib"

class TestMiddlewareAndHmr < Minitest::Test
  def test_middleware_gzip_negotiation_immutable_headers_etag_and_spa_fallback
    Dir.mktmpdir("rtf-mw-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "_next/static/chunks"))
      FileUtils.mkdir_p(File.join(dir, "docs"))

      js_body = "console.log('#{'x' * 400}');\n"
      js_path = File.join(dir, "app-8f91a0b2.js")
      File.write(js_path, js_body)

      # Write pre-compressed .gz sidecar
      Zlib::GzipWriter.open("#{js_path}.gz") { |gz| gz.write(js_body) }

      File.write(File.join(dir, "_next/static/chunks/page.js"), "window.__NEXT=1;\n")
      File.write(File.join(dir, "docs/index.html"), "<html>Docs Page</html>")
      File.write(File.join(dir, "index.html"), "<html>SPA Shell</html>")

      downstream = ->(_env) { [404, { "content-type" => "text/plain" }, ["Not Found"]] }
      mw = RubyToFaster::Middleware.new(downstream, root: dir, url_prefix: "/ui", spa_fallback: true)

      # 1. Serves precompressed .gz when Accept-Encoding includes gzip + immutable Cache-Control
      status, headers, body = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/ui/app-8f91a0b2.js",
        "HTTP_ACCEPT_ENCODING" => "br, gzip, deflate"
      )
      assert_equal 200, status
      assert_equal "gzip", headers["content-encoding"]
      assert_equal "public, max-age=31536000, immutable", headers["cache-control"]
      assert_equal js_body, Zlib::GzipReader.new(StringIO.new(body.first)).read

      # 2. Conditional ETag returns 304 Not Modified
      etag = headers["etag"]
      st304, _h304, body304 = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/ui/app-8f91a0b2.js",
        "HTTP_IF_NONE_MATCH" => etag
      )
      assert_equal 304, st304
      assert_empty body304

      # 3. Next.js static export clean route (`/ui/docs` -> `docs/index.html`)
      st_doc, h_doc, b_doc = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/ui/docs")
      assert_equal 200, st_doc
      assert_includes h_doc["content-type"], "text/html"
      assert_equal "<html>Docs Page</html>", b_doc.first

      # 4. Angular/Vite SPA fallback route (`/ui/settings/team` -> `index.html`)
      st_spa, _h_spa, b_spa = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/ui/settings/team",
        "HTTP_ACCEPT" => "text/html,application/xhtml+xml"
      )
      assert_equal 200, st_spa
      assert_equal "<html>SPA Shell</html>", b_spa.first

      # 5. Blocks `..` path traversal with 403 Forbidden
      st_bad, = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/ui/../../etc/passwd")
      assert_equal 403, st_bad

      # 6. Passes non-matching prefixes to downstream Rack app
      st_pass, = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/api/v1/health")
      assert_equal 404, st_pass
    end
  end

  def test_dev_server_hmr_tag_injection
    manifest = RubyToFaster::AssetManifest.new(
      "schema" => 1,
      "frameworks" => {
        "vite" => {
          "entrypoints" => {
            "src/main.ts" => { "file" => "assets/main-99.js", "css" => ["assets/main-99.css"] }
          }
        }
      }
    )

    hmr_html = manifest.html_tags("src/main.ts", framework: :vite, dev_server: "http://localhost:5173")
    assert_includes hmr_html, '<script type="module" src="http://localhost:5173/@vite/client"></script>'
    assert_includes hmr_html, '<script type="module" src="http://localhost:5173/src/main.ts"></script>'

    prod_html = manifest.html_tags("src/main.ts", framework: :vite, url_prefix: "/assets", dev_server: nil)
    assert_includes prod_html, '<link rel="stylesheet" href="/assets/assets/main-99.css">'
    assert_includes prod_html, '<script type="module" src="/assets/assets/main-99.js"></script>'
  end
end
