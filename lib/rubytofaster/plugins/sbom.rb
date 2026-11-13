# frozen_string_literal: true

require "digest"
require "json"

module RubyToFaster
  module Plugins
    # Generates a CycloneDX 1.5 Software Bill of Materials (`sbom.cdx.json`) covering
    # both Ruby gem dependencies and frontend `package.json` dependencies across
    # Vite, Next.js, and Angular workspaces.
    class SBOM
      def initialize(embed_in_gem: false, output_filename: nil)
        @embed_in_gem    = embed_in_gem
        @output_filename = output_filename
      end

      def generate_bundle(entries, config)
        return unless @embed_in_gem

        spec, = FileResolver.new(config).load_gemspec
        sbom_json = build_cyclonedx_json(spec, entries, config)
        entries["sbom.cdx.json"] = PackageEntry.new(
          gem_path: "sbom.cdx.json",
          source_path: nil,
          content: sbom_json,
          mode: 0o644,
          executable: false
        )
      end

      def after_package(result)
        target = @output_filename || "#{result.gem_path}.sbom.cdx.json"
        pkg = Gem::Package.new(result.gem_path)
        spec = pkg.spec

        doc = {
          "bomFormat"   => "CycloneDX",
          "specVersion" => "1.5",
          "version"     => 1,
          "metadata"    => {
            "tools" => [{ "vendor" => "HNM Labs", "name" => "rubytofaster", "version" => RubyToFaster::VERSION }],
            "component" => {
              "type"    => "library",
              "name"    => spec.name,
              "version" => spec.version.to_s,
              "purl"    => "pkg:gem/#{spec.name}@#{spec.version}",
              "hashes"  => [
                { "alg" => "SHA-256", "content" => result.gem_sha256 },
                { "alg" => "SHA-512", "content" => result.gem_sha512 }
              ].compact
            }
          },
          "components" => collect_runtime_components(spec, File.dirname(File.dirname(result.gem_path)))
        }

        File.write(target, "#{JSON.pretty_generate(doc)}\n")
      end

      private

      def build_cyclonedx_json(spec, entries, config)
        file_hashes = entries.keys.sort.map do |path|
          entry = entries[path]
          {
            "type" => "file",
            "name" => path,
            "hashes" => [{ "alg" => "SHA-256", "content" => Digest::SHA256.hexdigest(entry.bytes) }]
          }
        end

        doc = {
          "bomFormat"   => "CycloneDX",
          "specVersion" => "1.5",
          "version"     => 1,
          "metadata"    => {
            "tools" => [{ "vendor" => "HNM Labs", "name" => "rubytofaster", "version" => RubyToFaster::VERSION }],
            "component" => {
              "type"    => "library",
              "name"    => spec.name,
              "version" => spec.version.to_s,
              "purl"    => "pkg:gem/#{spec.name}@#{spec.version}"
            }
          },
          "components" => collect_runtime_components(spec, config.root_dir) + file_hashes
        }
        "#{JSON.pretty_generate(doc)}\n"
      end

      def collect_runtime_components(spec, root_dir)
        components = spec.runtime_dependencies.sort_by(&:name).map do |dep|
          {
            "type"    => "library",
            "name"    => dep.name,
            "version" => dep.requirement.to_s,
            "purl"    => "pkg:gem/#{dep.name}"
          }
        end

        # Discover frontend package.json dependencies in root and immediate workspaces
        Dir.glob(File.join(root_dir, "{,*/,*/*/}package.json")).sort.each do |pkg_json_path|
          next if pkg_json_path.include?("/node_modules/")

          data = JSON.parse(File.read(pkg_json_path))
          (data["dependencies"] || {}).sort_by(&:first).each do |npm_name, npm_ver|
            components << {
              "type"    => "library",
              "name"    => npm_name,
              "version" => npm_ver.to_s,
              "purl"    => "pkg:npm/#{npm_name}@#{npm_ver}"
            }
          end
        rescue JSON::ParserError
          next
        end

        components
      end
    end
  end
end
