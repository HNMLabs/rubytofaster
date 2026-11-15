# frozen_string_literal: true

require "test_helper"
require "stringio"
require "zlib"

class TestV03FixesAndGifBenchmark < Minitest::Test
  def test_parallel_workspace_wave_thread_safety_with_scripts_and_autorun
    Dir.mktmpdir("rtf-parallel-wave-") do |dir|
      # 4 independent gems in Wave 1 built concurrently across 4 threads
      %w[alpha beta gamma delta].each_with_index do |name, idx|
        gem_dir = File.join(dir, "gems", name)
        FileUtils.mkdir_p(File.join(gem_dir, "lib"))
        File.write(File.join(gem_dir, "lib/#{name}.rb"), "# frozen_string_literal: true\nmodule #{name.capitalize}; V = #{idx}; end\n")
        File.write(
          File.join(gem_dir, "#{name}.gemspec"),
          <<~RUBY
            Gem::Specification.new do |s|
              s.name    = "par_#{name}"
              s.version = "0.1.0"
              s.summary = "Parallel wave gem #{name}"
              s.authors = ["HNM Labs"]
              s.files   = Dir.glob("lib/**/*.rb")
            end
          RUBY
        )

        if idx.even?
          # Build script omitting explicit root_dir (relies on thread-local script root)
          File.write(
            File.join(gem_dir, "gem.build.rb"),
            <<~RUBY
              require "rubytofaster"
              RubyToFaster.build do |pkg|
                pkg.gemspec "#{name}.gemspec"
                pkg.reproducible = true
                pkg.validate_ruby_syntax
              end
            RUBY
          )
        else
          # Zero-config 1-liner autorun script (tests multi-gem re-entrancy)
          File.write(File.join(gem_dir, "gem.build.rb"), "require 'rubytofaster/autorun'\n")
        end
      end

      ws1 = RubyToFaster.workspace(root_dir: dir, parallel_jobs: 4)
      assert_equal [["par_alpha", "par_beta", "par_delta", "par_gamma"]], ws1.waves
      assert_equal 4, ws1.results.size
      assert_equal 0, ws1.cache_hits
      ws1.results.each do |res|
        assert File.file?(res.gem_path)
        Gem::Package.new(res.gem_path).verify
      end

      # Second parallel workspace run hits Merkle cache on all 4 gems
      ws2 = RubyToFaster.workspace(root_dir: dir, parallel_jobs: 4)
      assert_equal 4, ws2.cache_hits
      assert_equal ws1.results.map(&:gem_sha256), ws2.results.map(&:gem_sha256)
    end
  end

  def test_merkle_cache_invalidates_on_plugin_addition_metadata_and_dynamic_transform
    Dir.mktmpdir("rtf-cache-inv-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.binwrite(File.join(dir, "lib/code.rb"), "TOKEN = 'v1'\r\n")

      # 1. Build without RubyValidator (keeps CRLF)
      r1 = RubyToFaster.build(root_dir: dir, report: false) do |pkg|
        pkg.spec do |s|
          s.name     = "inv_demo"
          s.version  = "0.1.0"
          s.summary  = "Cache invalidation check"
          s.authors  = ["Alice"]
          s.homepage = "https://example.com/v1"
          s.files    = ["lib/code.rb"]
        end
      end
      refute r1.cache_hit

      # 2. Add RubyValidator -> must NOT return stale CRLF cache hit
      r2 = RubyToFaster.build(root_dir: dir, report: false) do |pkg|
        pkg.validate_ruby_syntax(normalize_newlines: true)
        pkg.spec do |s|
          s.name     = "inv_demo"
          s.version  = "0.1.0"
          s.summary  = "Cache invalidation check"
          s.authors  = ["Alice"]
          s.homepage = "https://example.com/v1"
          s.files    = ["lib/code.rb"]
        end
      end
      refute r2.cache_hit
      refute_equal r1.gem_sha256, r2.gem_sha256

      # 3. Repeat identical build with RubyValidator -> fast Merkle cache hit!
      r3 = RubyToFaster.build(root_dir: dir, report: false) do |pkg|
        pkg.validate_ruby_syntax(normalize_newlines: true)
        pkg.spec do |s|
          s.name     = "inv_demo"
          s.version  = "0.1.0"
          s.summary  = "Cache invalidation check"
          s.authors  = ["Alice"]
          s.homepage = "https://example.com/v1"
          s.files    = ["lib/code.rb"]
        end
      end
      assert r3.cache_hit
      assert_equal r2.gem_sha256, r3.gem_sha256

      # 4. Change gemspec homepage/authors -> must invalidate cache
      r4 = RubyToFaster.build(root_dir: dir, report: false) do |pkg|
        pkg.validate_ruby_syntax(normalize_newlines: true)
        pkg.spec do |s|
          s.name     = "inv_demo"
          s.version  = "0.1.0"
          s.summary  = "Cache invalidation check"
          s.authors  = ["Alice", "Bob"]
          s.homepage = "https://example.com/v2"
          s.files    = ["lib/code.rb"]
        end
      end
      refute r4.cache_hit

      # 5. Dynamic inline transform closure changing output -> must invalidate cache
      stamp = "STAMP_A"
      build_with_closure = lambda do
        RubyToFaster.build(root_dir: dir, report: false) do |pkg|
          pkg.transform { |_p, c| c.gsub("v1", stamp) }
          pkg.spec do |s|
            s.name    = "inv_demo"
            s.version = "0.1.0"
            s.summary = "Closure transform"
            s.authors = ["Alice"]
            s.files   = ["lib/code.rb"]
          end
        end
      end

      r5 = build_with_closure.call
      refute r5.cache_hit
      stamp = "STAMP_B"
      r6 = build_with_closure.call
      refute r6.cache_hit
      refute_equal r5.gem_sha256, r6.gem_sha256
    end
  end

  def test_blocks_parent_directory_symlink_escape_across_resolver_resources_and_middleware
    Dir.mktmpdir("rtf-outside-dir-") do |outside_dir|
      File.write(File.join(outside_dir, "secret.rb"), "SECRET = 'leaked'\n")
      File.write(File.join(outside_dir, "app.js"), "alert('leaked');\n")

      # 1. FileResolver blocks parent-directory symlink escape
      Dir.mktmpdir("rtf-parent-sym-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.symlink(outside_dir, File.join(dir, "lib/escaped"))

        assert_raises(RubyToFaster::SecurityError) do
          RubyToFaster.build(root_dir: dir, report: false) do |pkg|
            pkg.spec do |s|
              s.name    = "sym_parent_escape"
              s.version = "0.1.0"
              s.summary = "Parent symlink escape"
              s.authors = ["HNM Labs"]
              s.files   = ["lib/escaped/secret.rb"]
            end
          end
        end
      end

      # 2. Resources::Base blocks parent-directory symlink inside frontend dist/
      Dir.mktmpdir("rtf-res-sym-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/ok.rb"), "true\n")
        FileUtils.mkdir_p(File.join(dir, "frontend/dist"))
        File.write(File.join(dir, "frontend/vite.config.js"), "export default {}\n")
        File.symlink(outside_dir, File.join(dir, "frontend/dist/linked"))

        assert_raises(RubyToFaster::SecurityError) do
          RubyToFaster.build(root_dir: dir, report: false) do |pkg|
            pkg.vite root: "frontend", out_dir: "dist", mount_to: "public/vite"
            pkg.spec do |s|
              s.name    = "vite_sym_escape"
              s.version = "0.1.0"
              s.summary = "Vite dir symlink escape"
              s.authors = ["HNM Labs"]
              s.files   = ["lib/ok.rb"]
            end
          end
        end
      end

      # 3. Middleware refuses parent-directory symlink escape
      Dir.mktmpdir("rtf-mw-sym-") do |dir|
        File.symlink(outside_dir, File.join(dir, "linked"))
        mw = RubyToFaster::Middleware.new(->(_e) { [404, {}, ["Miss"]] }, root: dir, url_prefix: "/static")
        st, = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/static/linked/app.js")
        assert_equal 404, st
      end
    end
  end

  def test_middleware_percent_encoded_traversal_gzip_q0_and_distinct_etags
    Dir.mktmpdir("rtf-mw-http-") do |dir|
      js_body = "export const data = '#{'abc123_' * 60}';\n"
      js_path = File.join(dir, "chunk-a1b2c3d4.js")
      File.write(js_path, js_body)
      Zlib::GzipWriter.open("#{js_path}.gz") { |gz| gz.write(js_body) }

      mw = RubyToFaster::Middleware.new(->(_e) { [404, {}, ["Miss"]] }, root: dir, url_prefix: "/assets")

      # Percent-encoded traversal & null byte blocked with 403
      st_enc, = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/assets/%2e%2e/%2e%2e/etc/passwd")
      assert_equal 403, st_enc
      st_null, = mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/assets/chunk%00.js")
      assert_equal 403, st_null

      # Explicit gzip;q=0 must NOT return gzipped body
      st_plain, h_plain, b_plain = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/assets/chunk-a1b2c3d4.js",
        "HTTP_ACCEPT_ENCODING" => "gzip;q=0, identity;q=1"
      )
      assert_equal 200, st_plain
      refute h_plain.key?("content-encoding")
      assert_equal js_body, b_plain.first

      # Gzipped response has distinct `-gz` ETag suffix
      st_gz, h_gz, = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/assets/chunk-a1b2c3d4.js",
        "HTTP_ACCEPT_ENCODING" => "gzip"
      )
      assert_equal 200, st_gz
      assert_equal "gzip", h_gz["content-encoding"]
      refute_equal h_plain["etag"], h_gz["etag"]
      assert_includes h_gz["etag"], "-gz\""

      # Multi-ETag If-None-Match returns 304 with Vary: Accept-Encoding
      st_304, h_304, = mw.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/assets/chunk-a1b2c3d4.js",
        "HTTP_ACCEPT_ENCODING" => "gzip",
        "HTTP_IF_NONE_MATCH" => %(W/"stale-1", #{h_gz["etag"]})
      )
      assert_equal 304, st_304
      assert_equal "Accept-Encoding", h_304["vary"]
    end
  end

  def test_sbom_deep_out_dir_and_cli_subdirectory_gemspec
    Dir.mktmpdir("rtf-deep-sbom-") do |dir|
      sub = File.join(dir, "packages/widget")
      FileUtils.mkdir_p(File.join(sub, "lib"))
      FileUtils.mkdir_p(File.join(sub, "frontend"))
      File.write(File.join(sub, "lib/widget.rb"), "module Widget; end\n")
      File.write(
        File.join(sub, "frontend/package.json"),
        JSON.generate("name" => "widget-ui", "dependencies" => { "@angular/core" => "^19.0.0" })
      )
      File.write(
        File.join(sub, "widget.gemspec"),
        <<~RUBY
          Gem::Specification.new do |s|
            s.name    = "widget_gem"
            s.version = "0.2.0"
            s.summary = "Subdir gemspec + deep out_dir SBOM test"
            s.authors = ["HNM Labs"]
            s.files   = ["lib/widget.rb"]
          end
        RUBY
      )

      out = StringIO.new
      err = StringIO.new
      Dir.chdir(dir) do
        code = RubyToFaster::CLI.start(
          ["build", "packages/widget/widget.gemspec", "--sbom", "-o", "dist/deep/nested/gems", "--quiet"],
          out: out,
          err: err
        )
        assert_equal 0, code, err.string

        gem_file  = File.join(dir, "dist/deep/nested/gems/widget_gem-0.2.0.gem")
        sbom_file = "#{gem_file}.sbom.cdx.json"
        assert File.file?(gem_file)
        assert File.file?(sbom_file)

        sbom = JSON.parse(File.read(sbom_file))
        purls = sbom["components"].map { |c| c["purl"] }
        assert_includes purls, "pkg:npm/@angular/core@^19.0.0"
      end
    end
  end

  def test_real_benchmarker_and_gif89a_renderer_binary_and_lzw_decode
    Dir.mktmpdir("rtf-gif-bench-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/speedy.rb"), "# frozen_string_literal: true\nmodule Speedy; end\n")
      File.write(
        File.join(dir, "speedy.gemspec"),
        <<~RUBY
          Gem::Specification.new do |s|
            s.name    = "speedy_gem"
            s.version = "1.0.0"
            s.summary = "Real benchmark GIF verification"
            s.authors = ["HNM Labs"]
            s.files   = ["lib/speedy.rb"]
          end
        RUBY
      )

      gif_path  = File.join(dir, "out/benchmarks.gif")
      json_path = File.join(dir, "out/benchmarks.json")
      md_path   = File.join(dir, "out/benchmarks.md")

      out = StringIO.new
      err = StringIO.new
      Dir.chdir(dir) do
        code = RubyToFaster::CLI.start(
          ["bench", "-n", "2", "-w", "1", "--gif", gif_path, "--json-out", json_path, "--markdown-out", md_path],
          out: out,
          err: err
        )
        assert_equal 0, code, err.string
      end

      assert File.file?(gif_path)
      assert File.file?(json_path)
      assert File.file?(md_path)

      report = JSON.parse(File.read(json_path))
      assert_equal "speedy_gem", report["gem_name"]
      assert_equal 4, report["benchmarks"].size
      assert_operator report["peak_speedup"], :>, 1.0

      gif = File.binread(gif_path)
      assert_equal "GIF89a", gif.byteslice(0, 6)
      w, h, packed = gif.byteslice(6, 5).unpack("vvC")
      assert_equal RubyToFaster::GifRenderer::WIDTH, w
      assert_equal RubyToFaster::GifRenderer::HEIGHT, h
      assert_equal 0xF7, packed
      assert_includes gif, "NETSCAPE2.0".b
      assert_includes gif, "speedy_gem".b
      assert_equal 0x3B, gif.getbyte(-1)

      # Verify multi-frame Graphic Control Extensions (>= 18 frames)
      frame_count = gif.scan(/\x21\xF9\x04/n).size
      assert_operator frame_count, :>=, 18

      # Verify LZW round-trip across >1500 dictionary codes (9 -> 10 -> 11 bit width transitions)
      renderer = RubyToFaster::GifRenderer.new(report)
      complex_pixels = Array.new(8000) { |i| ((i * 73) ^ (i >> 3)) & 0x1B }.pack("C*")
      encoded_lzw = renderer.send(:lzw_encode_8bit, complex_pixels)
      decoded_pixels = lzw_decode_8bit_reference(encoded_lzw)
      assert_equal complex_pixels, decoded_pixels
    end
  end

  private

  # Reference GIF 8-bit LZW decoder to mathematically verify encoder bit-width transitions in tests.
  def lzw_decode_8bit_reference(bytes)
    clear_code = 256
    eoi_code   = 257
    code_size  = 9
    table      = {}
    reset_table = lambda do
      table.clear
      256.times { |i| table[i] = i.chr.b }
      code_size = 9
    end
    reset_table.call
    next_code = 258

    bit_pos = 0
    total_bits = bytes.bytesize * 8
    read_code = lambda do
      return nil if bit_pos + code_size > total_bits

      val = 0
      code_size.times do |b|
        byte_idx = (bit_pos + b) >> 3
        bit_idx  = (bit_pos + b) & 7
        val |= (((bytes.getbyte(byte_idx) >> bit_idx) & 1) << b)
      end
      bit_pos += code_size
      val
    end

    output = "".b
    prev_str = nil

    while (code = read_code.call)
      if code == clear_code
        reset_table.call
        next_code = 258
        prev_str = nil
        next
      elsif code == eoi_code
        break
      end

      entry = if table.key?(code)
                table[code]
              elsif code == next_code && prev_str
                prev_str + prev_str.byteslice(0, 1)
              else
                raise "Invalid LZW code #{code} (next_code=#{next_code}, code_size=#{code_size})"
              end

      output << entry
      if prev_str && next_code < 4096
        table[next_code] = prev_str + entry.byteslice(0, 1)
        next_code += 1
        code_size += 1 if next_code == (1 << code_size) && code_size < 12
      end
      prev_str = entry
    end

    output
  end
end
