# frozen_string_literal: true

require "pathname"

module RubyToFaster
  # Represents a single file entry destined for data.tar.gz inside a .gem package.
  PackageEntry = Struct.new(:gem_path, :source_path, :content, :mode, :executable, keyword_init: true) do
    def bytes
      content || File.binread(source_path)
    end

    def size
      content ? content.bytesize : File.size(source_path)
    end

    def virtual?
      !content.nil?
    end
  end

  # Resolves, validates, and tree-shakes files for a Gem::Specification.
  class FileResolver
    SECRET_PATTERNS = [
      /(?:\A|\/)\.env(?:\..+)?\z/,
      /(?:\A|\/)(?:id_rsa|id_ed25519|id_ecdsa|.*\.(?:pem|key|p12|pfx|keystore))\z/i,
      /(?:\A|\/)(?:credentials\.yml\.enc|master\.key|\.netrc|\.npmrc)\z/
    ].freeze

    def initialize(config)
      @config      = config
      @root_dir    = config.root_dir
      @root_real   = File.exist?(@root_dir) ? File.realpath(@root_dir) : @root_dir
      @root_prefix = @root_real.end_with?("/") ? @root_real : "#{@root_real}/"
    end

    def load_gemspec
      if @config.inline_spec_block
        spec = RubyToFaster.with_chdir(@root_dir) do
          Gem::Specification.new(&@config.inline_spec_block)
        end
        return [spec, nil]
      end

      spec_file = resolve_gemspec_path
      spec_dir  = File.dirname(spec_file)
      spec = RubyToFaster.with_chdir(spec_dir) { Gem::Specification.load(spec_file) }
      raise ConfigError, "Failed to load gemspec from #{spec_file}" unless spec

      [spec, spec_file]
    end

    # Resolves physical files into normalized PackageEntry records, applying tree-shaking
    # and strict path-traversal / symlink / secret guards.
    def resolve_entries(spec)
      candidates = Array(spec.files).dup

      unless @config.extra_includes.empty?
        @config.extra_includes.each do |glob|
          matched = Dir.glob(glob, base: @root_dir).select do |rel|
            File.file?(File.join(@root_dir, rel))
          end
          candidates.concat(matched)
        end
      end

      candidates = default_convention_files if candidates.empty?

      bindir = spec.bindir || "exe"
      executables = Array(spec.executables).map { |exe| File.join(bindir, exe) }

      entries       = {}
      pruned_files  = []
      verified_dirs = { @root_dir => true }

      candidates.uniq.each do |raw_path|
        norm = sanitize_relative_path!(raw_path)

        if excluded?(norm)
          pruned_files << norm
          next
        end

        full_path = File.expand_path(norm, @root_dir)
        verify_within_root!(norm, full_path)

        stat = begin
          File.lstat(full_path)
        rescue Errno::ENOENT
          next
        end

        if stat.symlink?
          verify_realpath_within_root!(norm, full_path, symlink: true)
          next unless File.file?(full_path)
        else
          next unless stat.file?

          parent_dir = File.dirname(full_path)
          unless verified_dirs[parent_dir]
            verify_realpath_within_root!(norm, parent_dir, symlink: false)
            verified_dirs[parent_dir] = true
          end
        end

        check_secret_file!(norm) if @config.strict_security

        target_stat = stat.symlink? ? File.stat(full_path) : stat
        is_exec = executables.include?(norm) || (target_stat.mode & 0o111) != 0
        entries[norm] = PackageEntry.new(
          gem_path: norm,
          source_path: full_path,
          content: nil,
          mode: is_exec ? 0o755 : 0o644,
          executable: is_exec
        )
      end

      [entries, pruned_files]
    end

    def sanitize_relative_path!(path)
      raise SecurityError, "Null byte detected in package path: #{path.inspect}" if path.to_s.include?("\0")

      cleaned = path.to_s.tr("\\", "/").sub(%r{\A\./+}, "")
      if cleaned.empty? || cleaned.start_with?("/")
        raise SecurityError, "Absolute or empty path is not allowed in gem package: #{path.inspect}"
      end

      segments = cleaned.split("/")
      if segments.include?("..")
        raise SecurityError, "Path traversal ('..') detected in gem package entry: #{path.inspect}"
      end

      segments.reject(&:empty?).join("/")
    end

    private

    def resolve_gemspec_path
      if @config.gemspec_path
        candidate = File.expand_path(@config.gemspec_path, @root_dir)
        raise ConfigError, "Gemspec file not found: #{candidate}" unless File.file?(candidate)

        return candidate
      end

      found = Dir.glob(File.join(@root_dir, "*.gemspec")).sort
      if found.empty?
        raise ConfigError, "No .gemspec found in #{@root_dir}. Specify `pkg.gemspec` or `pkg.spec { ... }`."
      end

      found.first
    end

    def default_convention_files
      code_files = Dir.glob("{lib,exe,bin,ext,sig}/**/*", base: @root_dir).select do |f|
        File.file?(File.join(@root_dir, f))
      end
      doc_files = Dir.glob("{LICENSE*,README*,CHANGELOG*,SECURITY*,*.gemspec}", base: @root_dir).select do |f|
        File.file?(File.join(@root_dir, f))
      end
      code_files + doc_files
    end

    def excluded?(norm_path)
      patterns = Config::DEFAULT_EXCLUDES + @config.extra_excludes
      patterns.any? do |pat|
        case pat
        when Regexp
          pat.match?(norm_path)
        else
          File.fnmatch?(pat.to_s, norm_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end
    end

    def verify_within_root!(norm_path, full_path)
      root_prefix = @root_dir.end_with?("/") ? @root_dir : "#{@root_dir}/"
      unless full_path == @root_dir || full_path.start_with?(root_prefix)
        raise SecurityError, "Resolved path escapes project root: #{norm_path}"
      end
    end

    def verify_realpath_within_root!(norm_path, full_path, symlink:)
      real_target = File.realpath(full_path)
      unless real_target == @root_real || real_target.start_with?(@root_prefix)
        raise SecurityError, "Symlink or parent directory '#{norm_path}' points outside project root to '#{real_target}'"
      end
    rescue Errno::ENOENT
      raise SecurityError, "Dangling symlink '#{norm_path}' is not permitted in gem package" if symlink
    end

    def check_secret_file!(norm_path)
      if SECRET_PATTERNS.any? { |rx| rx.match?(norm_path) }
        raise SecurityError, "Refusing to package potential secret file: #{norm_path}"
      end
    end
  end
end
