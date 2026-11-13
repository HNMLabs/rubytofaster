# frozen_string_literal: true

require "json"

module RubyToFaster
  module Plugins
    # Emits `.sha256` checksum files and SLSA-inspired `.provenance.json` build attestations
    # alongside built `.gem` artifacts for verifiable CI/CD releases.
    class Provenance
      PREDICATE_TYPE = "https://slsa.dev/provenance/v1"

      def after_package(result)
        sha_file = "#{result.gem_path}.sha256"
        File.write(sha_file, "#{result.gem_sha256}  #{File.basename(result.gem_path)}\n")

        attestation = {
          "_type" => "https://in-toto.io/Statement/v1",
          "subject" => [
            {
              "name" => File.basename(result.gem_path),
              "digest" => {
                "sha256" => result.gem_sha256,
                "sha512" => result.gem_sha512
              }.compact
            }
          ],
          "predicateType" => PREDICATE_TYPE,
          "predicate" => {
            "buildDefinition" => {
              "buildType" => "https://github.com/HNMLabs/rubytofaster@v#{RubyToFaster::VERSION}",
              "externalParameters" => {
                "gem_name"    => result.gem_name,
                "gem_version" => result.gem_version,
                "cache_key"   => result.cache_key,
                "entry_count" => result.entry_count,
                "resources"   => result.resources.map { |r| r.is_a?(Hash) ? r[:framework] : r.framework }
              }
            },
            "runDetails" => {
              "builder" => {
                "id" => ENV["GITHUB_ACTIONS"] == "true" ? "https://github.com/actions/runner" : "local-rubytofaster-cli",
                "ruby_version" => RUBY_VERSION,
                "ruby_platform" => RUBY_PLATFORM
              }
            }
          }
        }

        File.write("#{result.gem_path}.provenance.json", "#{JSON.pretty_generate(attestation)}\n")
      end
    end
  end
end
