# frozen_string_literal: true

require "test_helper"

class TestPluginsSbomProvenance < Minitest::Test
  def test_precompress_sbom_and_provenance_plugins
    Dir.mktmpdir("rtf-std-plugins-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "frontend/dist/assets"))
      File.write(File.join(dir, "lib/demo.rb"), "module Demo\r\n  X = 1\r\nend\r\n")
      File.write(File.join(dir, "frontend/vite.config.js"), "export default {}\n")
      File.write(
        File.join(dir, "frontend/package.json"),
        JSON.generate("name" => "ui", "dependencies" => { "vue" => "^3.5.0" })
      )
      # Large compressible asset so .gz sidecar is smaller than raw
      File.write(File.join(dir, "frontend/dist/assets/bundle.js"), "export const msg = '#{'hello_vite_' * 80}';\n")

      res = RubyToFaster.build(root_dir: dir, report: false) do |pkg|
        pkg.validate_ruby_syntax
        pkg.vite root: "frontend", out_dir: "dist", mount_to: "public/vite"
        pkg.precompress_assets(min_bytes: 128)
        pkg.generate_sbom(embed_in_gem: true)
        pkg.generate_provenance

        pkg.spec do |s|
          s.name    = "secure_pkg"
          s.version = "1.0.0"
          s.summary = "Built-in plugins test"
          s.authors = ["HNM Labs"]
          s.files   = ["lib/demo.rb"]
          s.add_Dependency("rack", ">= 2.2") if s.respond_to?(:add_Dependency)
          s.add_runtime_dependency("rack", ">= 2.2")
        end
      end

      # External attestations generated alongside .gem
      sha_path  = "#{res.gem_path}.sha256"
      prov_path = "#{res.gem_path}.provenance.json"
      sbom_path = "#{res.gem_path}.sbom.cdx.json"
      assert File.file?(sha_path)
      assert File.file?(prov_path)
      assert File.file?(sbom_path)

      assert_includes File.read(sha_path), res.gem_sha256
      prov = JSON.parse(File.read(prov_path))
      assert_equal "https://slsa.dev/provenance/v1", prov["predicateType"]

      sbom = JSON.parse(File.read(sbom_path))
      assert_equal "CycloneDX", sbom["bomFormat"]
      purls = sbom["components"].map { |c| c["purl"] }
      assert_includes purls, "pkg:gem/rack"
      assert_includes purls, "pkg:npm/vue@^3.5.0"

      # Inspect .gem to confirm `.gz` sidecar and embedded `sbom.cdx.json` + LF normalized Ruby
      info = RubyToFaster.inspect_gem(res.gem_path)
      entry_paths = info[:entries].map { |e| e[:path] }
      assert_includes entry_paths, "public/vite/assets/bundle.js.gz"
      assert_includes entry_paths, "sbom.cdx.json"
    end
  end

  def test_ruby_validator_catches_syntax_error_at_build_time
    Dir.mktmpdir("rtf-bad-rb-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/broken.rb"), "def unclosed_method(\n  1 + 2\n")

      err = assert_raises(RubyToFaster::BuildError) do
        RubyToFaster.build(root_dir: dir, report: false) do |pkg|
          pkg.validate_ruby_syntax
          pkg.spec do |s|
            s.name    = "broken_gem"
            s.version = "0.1.0"
            s.summary = "Invalid Ruby syntax"
            s.authors = ["HNM Labs"]
            s.files   = ["lib/broken.rb"]
          end
        end
      end
      assert_match(/Ruby syntax error in lib\/broken\.rb/, err.message)
    end
  end
end
