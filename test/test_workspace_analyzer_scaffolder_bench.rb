# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestWorkspaceAnalyzerScaffolderBench < Minitest::Test
  def test_workspace_topological_waves_and_cycle_detection
    Dir.mktmpdir("rtf-monorepo-") do |dir|
      create_member_gem(dir, "packages/core", "acme_core", deps: [])
      create_member_gem(dir, "packages/http", "acme_http", deps: ["acme_core"])
      create_member_gem(dir, "packages/ui",   "acme_ui",   deps: ["acme_core", "acme_http"])

      ws = RubyToFaster.workspace(root_dir: dir)
      assert_equal [["acme_core"], ["acme_http"], ["acme_ui"]], ws.waves
      assert_equal 3, ws.results.size
      assert_equal 0, ws.cache_hits

      # Second workspace build hits Merkle cache across all 3 gems!
      ws2 = RubyToFaster.workspace(root_dir: dir)
      assert_equal 3, ws2.cache_hits
    end

    # Circular dependency check
    Dir.mktmpdir("rtf-cycle-") do |dir|
      create_member_gem(dir, "gems/alpha", "alpha_gem", deps: ["beta_gem"])
      create_member_gem(dir, "gems/beta",  "beta_gem",  deps: ["alpha_gem"])

      assert_raises(RubyToFaster::ConfigError) do
        RubyToFaster.workspace(root_dir: dir)
      end
    end
  end

  def test_scaffolder_fullstack_new_and_analyzer_html_report
    Dir.mktmpdir("rtf-scaffold-") do |dir|
      out = StringIO.new
      err = StringIO.new

      Dir.chdir(dir) do
        code = RubyToFaster::CLI.start(["new", "nova_studio", "--fullstack"], out: out, err: err)
        assert_equal 0, code, err.string

        gem_dir = File.join(dir, "nova_studio")
        assert File.file?(File.join(gem_dir, "gem.build.rb"))
        assert File.file?(File.join(gem_dir, "sig/nova_studio.rbs"))

        # Build the newly scaffolded fullstack (Vite + Next.js + Angular) gem!
        Dir.chdir(gem_dir) do
          build_out = StringIO.new
          assert_equal 0, RubyToFaster::CLI.start(["build"], out: build_out, err: err)
          built_gem = "pkg/nova_studio-0.1.0.gem"
          assert File.file?(built_gem)

          # Analyze it & generate interactive HTML treemap dashboard
          analyze_out = StringIO.new
          assert_equal 0, RubyToFaster::CLI.start(
            ["analyze", built_gem, "--html", "pkg/bundle-report.html", "--json"],
            out: analyze_out,
            err: err
          )
          report = JSON.parse(analyze_out.string)
          assert_includes report["categories"].keys, "vite_assets"
          assert_includes report["categories"].keys, "nextjs_assets"
          assert_includes report["categories"].keys, "angular_assets"
          assert File.file?("pkg/bundle-report.html")
          assert_includes File.read("pkg/bundle-report.html"), "RubyToFaster Bundle Analyzer"
        end
      end
    end
  end

  def test_cli_bench_runs_cleanly
    Dir.mktmpdir("rtf-bench-cli-") do |dir|
      create_member_gem(dir, ".", "bench_sample", deps: [])
      out = StringIO.new
      err = StringIO.new
      Dir.chdir(dir) do
        assert_equal 0, RubyToFaster::CLI.start(["bench", "-n", "2", "--json"], out: out, err: err)
        data = JSON.parse(out.string)
        assert_equal "bench_sample", data["gem_name"]
        assert_operator data["benchmarks"].size, :>=, 3
      end
    end
  end

  private

  def create_member_gem(root, rel_dir, name, deps:)
    full = File.join(root, rel_dir)
    FileUtils.mkdir_p(File.join(full, "lib"))
    File.write(File.join(full, "lib/#{name}.rb"), "# frozen_string_literal: true\nmodule #{name.capitalize.gsub('_', '')}; end\n")
    dep_lines = deps.map { |d| "s.add_runtime_dependency #{d.dump}, '>= 0'" }.join("\n  ")
    File.write(
      File.join(full, "#{name}.gemspec"),
      <<~RUBY
        Gem::Specification.new do |s|
          s.name    = #{name.dump}
          s.version = "0.1.0"
          s.summary = "Workspace member #{name}"
          s.authors = ["HNM Labs"]
          s.files   = ["lib/#{name}.rb"]
          #{dep_lines}
        end
      RUBY
    )
  end
end
