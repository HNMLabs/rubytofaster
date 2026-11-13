# frozen_string_literal: true

require "json"

module RubyToFaster
  # Builds unified frontend resource manifests and zero-dependency Ruby runtime asset helpers
  # with built-in Vite / Next.js / Angular Dev-Server HMR support and Rack middleware mounting.
  class AssetManifest
    MANIFEST_SCHEMA = 1

    attr_reader :data

    def initialize(manifest_hash)
      @data = manifest_hash
    end

    def self.from_adapter_results(results)
      frameworks = {}
      results.each do |res|
        key = res.framework.to_s
        frameworks[key] = {
          "mount_to" => res.mount_to,
          "entrypoints" => deep_stringify(res.entrypoints),
          "assets" => deep_stringify(res.assets),
          "metadata" => deep_stringify(res.metadata)
        }
      end

      new(
        "schema" => MANIFEST_SCHEMA,
        "generator" => "rubytofaster/#{RubyToFaster::VERSION}",
        "frameworks" => frameworks
      )
    end

    def self.load_file(path)
      new(JSON.parse(File.read(path)))
    end

    def to_json_pretty
      "#{JSON.pretty_generate(@data)}\n"
    end

    def frameworks
      (@data["frameworks"] || {}).keys
    end

    # Resolves a logical asset or entrypoint path to its mounted relative URL/file path.
    def asset_path(logical_name, framework: nil)
      fw_map = @data["frameworks"] || {}
      targets = framework ? { framework.to_s => fw_map[framework.to_s] }.compact : fw_map

      targets.each_value do |info|
        ep = info.dig("entrypoints", logical_name.to_s)
        return ep["file"] if ep && ep["file"]

        asset = info.dig("assets", logical_name.to_s)
        return logical_name.to_s if asset
      end
      nil
    end

    # Generates `<link rel="stylesheet">` and `<script type="module">` HTML tags for an entrypoint.
    # When `dev_server:` (or `ENV["RTF_DEV_SERVER"]`) is provided, emits live HMR dev-server script tags!
    def html_tags(entry_name, framework: nil, url_prefix: "/", dev_server: ENV["RTF_DEV_SERVER"])
      if dev_server && !dev_server.to_s.strip.empty?
        return dev_hmr_tags(entry_name, framework: framework, dev_server: dev_server)
      end

      prefix = url_prefix.end_with?("/") ? url_prefix : "#{url_prefix}/"
      fw_map = @data["frameworks"] || {}
      targets = framework ? { framework.to_s => fw_map[framework.to_s] }.compact : fw_map

      targets.each_value do |info|
        ep = info.dig("entrypoints", entry_name.to_s)
        next unless ep

        tags = []
        Array(ep["css"]).each do |css_rel|
          tags << %(<link rel="stylesheet" href="#{prefix}#{css_rel.sub(%r{\A/}, '')}">)
        end
        scripts = ep["scripts"] ? Array(ep["scripts"]) : [ep["file"]].compact
        scripts.each do |js_rel|
          tags << %(<script type="module" src="#{prefix}#{js_rel.sub(%r{\A/}, '')}"></script>)
        end
        return tags.join("\n")
      end

      ""
    end

    # Emits a standalone, zero-dependency Ruby helper file that can be required inside the target gem.
    def generate_ruby_helper_source(module_name)
      embedded_json = JSON.generate(@data)
      parts = module_name.to_s.split("::").reject(&:empty?)
      raise ConfigError, "Invalid Ruby module name: #{module_name.inspect}" if parts.empty?

      indent = "  "
      openers = parts.each_with_index.map { |mod, idx| "#{indent * idx}module #{mod}" }.join("\n")
      closers = (parts.size - 1).downto(0).map { |idx| "#{indent * idx}end" }.join("\n")
      body_indent = indent * parts.size

      body = <<~RUBY
        MANIFEST = JSON.parse(#{embedded_json.dump}).freeze

        def self.manifest
          MANIFEST
        end

        def self.asset_path(name, framework: nil)
          fws = MANIFEST["frameworks"] || {}
          scope = framework ? { framework.to_s => fws[framework.to_s] }.compact : fws
          scope.each_value do |info|
            ep = info.dig("entrypoints", name.to_s)
            return ep["file"] if ep && ep["file"]
            return name.to_s if info.dig("assets", name.to_s)
          end
          nil
        end

        def self.html_tags(entry, framework: nil, url_prefix: "/", dev_server: ENV["RTF_DEV_SERVER"])
          if dev_server && !dev_server.to_s.strip.empty?
            base = dev_server.to_s.chomp("/")
            clean = entry.to_s.sub(%r{\\A/}, "")
            if framework.nil? || framework.to_s == "vite"
              return [
                %(<script type="module" src="\#{base}/@vite/client"></script>),
                %(<script type="module" src="\#{base}/\#{clean}"></script>)
              ].join("\\n")
            end
            return %(<script type="module" src="\#{base}/\#{clean}"></script>)
          end

          prefix = url_prefix.end_with?("/") ? url_prefix : "\#{url_prefix}/"
          fws = MANIFEST["frameworks"] || {}
          scope = framework ? { framework.to_s => fws[framework.to_s] }.compact : fws
          scope.each_value do |info|
            ep = info.dig("entrypoints", entry.to_s)
            next unless ep

            tags = []
            Array(ep["css"]).each { |c| tags << %(<link rel="stylesheet" href="\#{prefix}\#{c.sub(%r{\\A/}, '')}">) }
            scripts = ep["scripts"] ? Array(ep["scripts"]) : [ep["file"]].compact
            scripts.each { |j| tags << %(<script type="module" src="\#{prefix}\#{j.sub(%r{\\A/}, '')}"></script>) }
            return tags.join("\\n")
          end
          ""
        end
      RUBY

      indented_body = body.lines.map { |l| l.strip.empty? ? "\n" : "#{body_indent}#{l}" }.join

      <<~FILE
        # frozen_string_literal: true
        # Generated by RubyToFaster v#{RubyToFaster::VERSION} — DO NOT EDIT MANUALLY

        require "json"

        #{openers}
        #{indented_body.chomp}
        #{closers}
      FILE
    end

    def self.deep_stringify(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        obj.map { |v| deep_stringify(v) }
      when Symbol
        obj.to_s
      else
        obj
      end
    end

    private

    def dev_hmr_tags(entry_name, framework:, dev_server:)
      base  = dev_server.to_s.chomp("/")
      clean = entry_name.to_s.sub(%r{\A/}, "")
      if framework.nil? || framework.to_s == "vite"
        [
          %(<script type="module" src="#{base}/@vite/client"></script>),
          %(<script type="module" src="#{base}/#{clean}"></script>)
        ].join("\n")
      else
        %(<script type="module" src="#{base}/#{clean}"></script>)
      end
    end
  end
end
