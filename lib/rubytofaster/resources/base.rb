# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module RubyToFaster
  module Resources
    # Result returned by each frontend framework adapter (Vite, Next.js, Angular).
    AdapterResult = Struct.new(
      :framework,
      :root,
      :mount_to,
      :entries,
      :entrypoints,
      :assets,
      :metadata,
      :duration_ms,
      keyword_init: true
    )

    # Shared base class for Angular, Vite, and Next.js resource adapters.
    class Base
      SOURCE_MAP_EXT = /\.map\z/i

      def initialize(project_root:, spec_config:, file_resolver:)
        @project_root  = project_root
        @spec_config   = spec_config
        @file_resolver = file_resolver
        @options       = spec_config[:options] || {}
      end

      def workspace_dir
        File.expand_path(@spec_config[:root] || ".", @project_root)
      end

      def mount_to
        @file_resolver.sanitize_relative_path!(@spec_config[:mount_to])
      end

      def include_sourcemaps?
        @options.fetch(:sourcemaps, false)
      end

      protected

      # Executes a frontend build command safely without invoking a subshell (`sh -c`),
      # preventing command injection vulnerabilities.
      def run_build_command!(default_script_args)
        return unless @spec_config[:auto_build] || @spec_config[:build_command]

        argv = resolve_command_argv(@spec_config[:build_command], default_script_args)
        env = { "NODE_ENV" => "production", "CI" => "true" }

        stdout, stderr, status = Open3.capture3(env, *argv, chdir: workspace_dir)
        return if status.success?

        raise BuildError, <<~MSG.strip
          #{framework_name} build failed in #{workspace_dir} (exit #{status.exitstatus}):
          Command: #{argv.join(' ')}
          #{stderr.empty? ? stdout : stderr}
        MSG
      rescue Errno::ENOENT => e
        raise BuildError, "Executable not found while building #{framework_name} resources: #{e.message}"
      end

      def resolve_command_argv(custom_cmd, default_args)
        if custom_cmd.is_a?(Array)
          raise ConfigError, "Build command array cannot be empty" if custom_cmd.empty?

          return custom_cmd.map(&:to_s)
        elsif custom_cmd.is_a?(String)
          raise ConfigError, <<~MSG.strip
            String build commands are disallowed for security (shell injection prevention).
            Pass an Array of arguments instead, e.g. `build_command: ["npm", "run", "build"]`.
          MSG
        end

        pkg_manager = detect_package_manager(workspace_dir)
        [pkg_manager, *default_args]
      end

      def detect_package_manager(dir)
        return "pnpm" if File.exist?(File.join(dir, "pnpm-lock.yaml"))
        return "yarn" if File.exist?(File.join(dir, "yarn.lock"))
        return "bun"  if File.exist?(File.join(dir, "bun.lockb")) || File.exist?(File.join(dir, "bun.lock"))

        "npm"
      end

      # Collects all production files under `dir` and maps them to virtual/staged PackageEntry objects.
      def stage_directory(dir, target_mount: mount_to, ignore_patterns: [])
        unless Dir.exist?(dir)
          raise BuildError, "#{framework_name} build output directory not found: #{dir}"
        end

        real_base = File.realpath(dir)
        real_base_prefix = real_base.end_with?("/") ? real_base : "#{real_base}/"

        staged = {}
        asset_map = {}

        Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.each do |rel|
          next if rel == "." || rel == ".." || rel.end_with?("/.", "/..")
          next if !include_sourcemaps? && SOURCE_MAP_EXT.match?(rel)
          next if ignore_patterns.any? { |rx| rx.match?(rel) }

          full = File.join(dir, rel)
          stat = File.lstat(full)
          if stat.symlink? || contains_symlink_segment?(dir, rel)
            raise SecurityError, "Symlinks inside #{framework_name} build output are disallowed: #{rel}"
          end
          next unless stat.file?

          real_full = File.realpath(full)
          unless real_full.start_with?(real_base_prefix)
            raise SecurityError, "#{framework_name} asset escapes output directory: #{rel}"
          end

          clean_rel = @file_resolver.sanitize_relative_path!(rel)
          gem_dest  = @file_resolver.sanitize_relative_path!(File.join(target_mount, clean_rel))

          staged[gem_dest] = PackageEntry.new(
            gem_path: gem_dest,
            source_path: full,
            content: nil,
            mode: 0o644,
            executable: false
          )
          asset_map[clean_rel] = {
            gem_path: gem_dest,
            size: stat.size,
            sha256: Digest::SHA256.file(full).hexdigest
          }
        end

        [staged, asset_map]
      end

      def contains_symlink_segment?(base_dir, rel_path)
        cursor = base_dir
        rel_path.split("/").each do |part|
          next if part.empty?

          cursor = File.join(cursor, part)
          return true if File.symlink?(cursor)
        end
        false
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end
  end
end
