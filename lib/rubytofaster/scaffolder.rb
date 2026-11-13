# frozen_string_literal: true

require "fileutils"

module RubyToFaster
  # Scaffolds a modern, zero-Rake, script-first Ruby gem (`rtf new <name>`) with optional
  # Vite, Next.js, or Angular frontend workspaces and Rack middleware integration.
  class Scaffolder
    VALID_GEM_NAME = /\A[a-z][a-z0-9_-]*\z/

    def initialize(gem_name, target_dir: nil, vite: false, nextjs: false, angular: false)
      unless VALID_GEM_NAME.match?(gem_name.to_s)
        raise ConfigError, "Invalid gem name #{gem_name.inspect}. Use lowercase letters, digits, '_', or '-'."
      end

      @gem_name    = gem_name
      @module_name = camelize(gem_name)
      @req_path    = gem_name.tr("-", "/")
      @target_dir  = File.expand_path(target_dir || gem_name, Dir.pwd)
      @vite        = vite
      @nextjs      = nextjs
      @angular     = angular
    end

    def generate!
      if Dir.exist?(@target_dir) && !Dir.empty?(@target_dir)
        raise ConfigError, "Target directory already exists and is not empty: #{@target_dir}"
      end

      write_rel(".gitignore", gitignore_content)
      write_rel("#{@gem_name}.gemspec", gemspec_content)
      write_rel("gem.build.rb", build_script_content, executable: true)
      write_rel("lib/#{@req_path}/version.rb", version_rb_content)
      write_rel("lib/#{@req_path}.rb", main_rb_content)
      write_rel("sig/#{@req_path}.rbs", rbs_content)
      write_rel("test/test_#{@gem_name.tr('-', '_')}.rb", test_content)
      write_rel("README.md", readme_content)

      scaffold_frontend_starters!
      @target_dir
    end

    private

    def has_frontend?
      @vite || @nextjs || @angular
    end

    def write_rel(rel_path, content, executable: false)
      dest = File.join(@target_dir, rel_path)
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, content)
      File.chmod(0o755, dest) if executable
    end

    def camelize(str)
      str.split(/[-_]/).map(&:capitalize).join
    end

    def gitignore_content
      <<~TXT
        /.rtf-cache/
        /pkg/
        *.gem
        *.sha256
        *.provenance.json
        *.sbom.cdx.json
        node_modules/
        dist/
        .next/
        out/
        .angular/
      TXT
    end

    def gemspec_content
      <<~RUBY
        # frozen_string_literal: true

        require_relative "lib/#{@req_path}/version"

        Gem::Specification.new do |spec|
          spec.name                  = #{@gem_name.dump}
          spec.version               = #{@module_name}::VERSION
          spec.authors               = ["Developer"]
          spec.summary               = "Minimalist Ruby gem built with RubyToFaster."
          spec.license               = "MIT"
          spec.required_ruby_version = ">= 3.0.0"

          spec.files = Dir.chdir(__dir__) do
            Dir.glob("{lib,exe,sig}/**/*").select { |f| File.file?(f) } +
              %w[README.md #{@gem_name}.gemspec]
          end
          spec.require_paths = ["lib"]
        end
      RUBY
    end

    def build_script_content
      lines = [
        "#!/usr/bin/env ruby",
        "# frozen_string_literal: true",
        "",
        'require "rubytofaster"',
        "",
        "RubyToFaster.build(root_dir: __dir__) do |pkg|",
        "  pkg.gemspec \"#{@gem_name}.gemspec\"",
        "  pkg.incremental  = true",
        "  pkg.reproducible = true",
        "  pkg.validate_ruby_syntax"
      ]

      if @vite
        lines << '  pkg.vite root: "frontend", out_dir: "dist", mount_to: "public/vite"'
      end
      if @nextjs
        lines << '  pkg.nextjs root: "portal", mode: :auto, mount_to: "public/nextjs"'
      end
      if @angular
        lines << '  pkg.angular root: "admin", project: "admin", mount_to: "public/angular"'
      end
      if has_frontend?
        lines << "  pkg.precompress_assets"
        lines << "  pkg.generate_asset_helper module_name: \"#{@module_name}::Assets\", path: \"lib/#{@req_path}/assets.rb\""
      end

      lines << "  pkg.budget max_compressed_kb: 512, max_unpacked_kb: 2048"
      lines << "end"
      "#{lines.join("\n")}\n"
    end

    def version_rb_content
      <<~RUBY
        # frozen_string_literal: true

        module #{@module_name}
          VERSION = "0.1.0"
        end
      RUBY
    end

    def main_rb_content
      <<~RUBY
        # frozen_string_literal: true

        require_relative "#{File.basename(@req_path)}/version"

        module #{@module_name}
        end
      RUBY
    end

    def rbs_content
      <<~RBS
        module #{@module_name}
          VERSION: String
        end
      RBS
    end

    def test_content
      <<~RUBY
        # frozen_string_literal: true

        $LOAD_PATH.unshift File.expand_path("../lib", __dir__)
        require "#{@req_path}"
        require "minitest/autorun"

        class Test#{@module_name} < Minitest::Test
          def test_version_defined
            refute_nil #{@module_name}::VERSION
          end
        end
      RUBY
    end

    def readme_content
      <<~MD
        # #{@module_name}

        Built with [RubyToFaster](https://github.com/HNMLabs/rubytofaster).

        ## Build & Inspect

        ```bash
        ./gem.build.rb
        rtf inspect pkg/#{@gem_name}-0.1.0.gem
        ```
      MD
    end

    def scaffold_frontend_starters!
      if @vite
        write_rel("frontend/vite.config.js", "export default { build: { manifest: true, outDir: 'dist' } };\n")
        write_rel("frontend/dist/.vite/manifest.json", "{\n  \"src/main.js\": { \"file\": \"assets/main-init.js\", \"isEntry\": true }\n}\n")
        write_rel("frontend/dist/assets/main-init.js", "console.log('#{@gem_name} vite ready');\n")
      end

      if @nextjs
        write_rel("portal/next.config.mjs", "export default { output: 'export' };\n")
        write_rel("portal/out/index.html", "<!doctype html><html><body><h1>#{@module_name} Portal</h1></body></html>\n")
      end

      return unless @angular

      angular_json = <<~JSON
        {
          "version": 1,
          "projects": {
            "admin": {
              "architect": {
                "build": {
                  "options": {
                    "outputPath": { "base": "dist/admin", "browser": "browser" }
                  }
                }
              }
            }
          }
        }
      JSON
      write_rel("admin/angular.json", angular_json)
      write_rel("admin/dist/admin/browser/index.html", "<!doctype html><html><body><app-root></app-root><script src=\"main-init.js\"></script></body></html>\n")
      write_rel("admin/dist/admin/browser/main-init.js", "console.log('#{@gem_name} angular ready');\n")
    end
  end
end
