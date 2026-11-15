# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/package"
require "stringio"
require "yaml"
require "zlib"

module RubyToFaster
  # Direct, deterministic in-memory `.gem` compiler producing RubyGems v2.0+ archives
  # (`metadata.gz`, `data.tar.gz`, `checksums.yaml.gz`) without Rake or temporary file trees.
  class Packager
    # Deterministic default timestamp matching RubyGems reproducible epoch (1980-01-02 UTC).
    DEFAULT_EPOCH = 315_619_200
    EPOCH_MUTEX   = Mutex.new

    PackageStats = Struct.new(
      :gem_path,
      :gem_sha256,
      :gem_sha512,
      :compressed_bytes,
      :unpacked_bytes,
      :entry_count,
      :entry_sizes,
      keyword_init: true
    )

    def initialize(config, plugin_runner)
      @config        = config
      @plugin_runner = plugin_runner
    end

    def build(spec:, entries:, out_path:, already_transformed: false)
      validate_spec!(spec)
      epoch = resolve_epoch

      effective_spec = prepare_spec(spec, entries, epoch)

      metadata_gz_bytes, meta_digests = build_metadata_gz(effective_spec, epoch)
      data_tar_gz_bytes, data_digests, unpacked_bytes, entry_sizes = build_data_tar_gz(
        entries,
        epoch,
        already_transformed: already_transformed
      )
      checksums_gz_bytes = build_checksums_gz(
        {
          "metadata.gz" => meta_digests,
          "data.tar.gz" => data_digests
        },
        epoch
      )

      outer_buf = StringIO.new(String.new(capacity: data_tar_gz_bytes.bytesize + 8192, encoding: Encoding::BINARY))
      with_reproducible_epoch(epoch) do
        Gem::Package::TarWriter.new(outer_buf) do |outer_tar|
          add_tar_bytes(outer_tar, "metadata.gz", 0o444, metadata_gz_bytes)
          add_tar_bytes(outer_tar, "data.tar.gz", 0o444, data_tar_gz_bytes)
          add_tar_bytes(outer_tar, "checksums.yaml.gz", 0o444, checksums_gz_bytes)
        end
      end

      gem_bytes = outer_buf.string
      FileUtils.mkdir_p(File.dirname(out_path))
      File.binwrite(out_path, gem_bytes)

      PackageStats.new(
        gem_path: out_path,
        gem_sha256: Digest::SHA256.hexdigest(gem_bytes),
        gem_sha512: Digest::SHA512.hexdigest(gem_bytes),
        compressed_bytes: gem_bytes.bytesize,
        unpacked_bytes: unpacked_bytes,
        entry_count: entry_sizes.size,
        entry_sizes: entry_sizes
      )
    end

    private

    def validate_spec!(spec)
      missing = []
      missing << "name" if spec.name.nil? || spec.name.to_s.strip.empty?
      missing << "version" if spec.version.nil?
      missing << "summary" if spec.summary.nil? || spec.summary.to_s.strip.empty?
      missing << "authors" if Array(spec.authors).empty?

      return if missing.empty?

      raise ConfigError, "Gem::Specification is missing required fields: #{missing.join(', ')}"
    end

    def resolve_epoch
      return @config.source_date_epoch if @config.source_date_epoch
      return DEFAULT_EPOCH if @config.reproducible

      Time.now.to_i
    end

    def prepare_spec(spec, entries, epoch)
      cloned = spec.dup
      sorted_files = entries.keys.sort
      cloned.files = sorted_files

      bindir_prefix = "#{cloned.bindir || 'exe'}/"
      cloned.executables = Array(cloned.executables).select do |exe|
        entries.key?("#{bindir_prefix}#{exe}")
      end

      cloned.date = Time.at(epoch).utc if @config.reproducible
      cloned.mark_version
      cloned
    end

    def build_metadata_gz(spec, epoch)
      yaml_bytes = spec.to_yaml
      gz_bytes   = gzip_deterministic(yaml_bytes, epoch)
      [gz_bytes, compute_digests(gz_bytes)]
    end

    def build_data_tar_gz(entries, epoch, already_transformed:)
      unpacked_total = 0
      entry_sizes    = {}
      tar_buffer     = StringIO.new("".b)

      prepared = entries.keys.sort.map do |gem_path|
        entry = entries[gem_path]
        raw_bytes = entry.bytes
        final_bytes = if already_transformed
                        raw_bytes.b
                      else
                        @plugin_runner.run_transform(gem_path, raw_bytes).b
                      end
        unpacked_total += final_bytes.bytesize
        entry_sizes[gem_path] = final_bytes.bytesize
        [gem_path, entry.mode, final_bytes]
      end

      with_reproducible_epoch(epoch) do
        Gem::Package::TarWriter.new(tar_buffer) do |data_tar|
          prepared.each do |gem_path, mode, final_bytes|
            add_tar_bytes(data_tar, gem_path, mode, final_bytes)
          end
        end
      end

      tar_bytes = tar_buffer.string
      gz_bytes  = gzip_deterministic(tar_bytes, epoch)
      [gz_bytes, compute_digests(gz_bytes), unpacked_total, entry_sizes]
    end

    def build_checksums_gz(digests_by_entry, epoch)
      Gem.load_yaml
      by_algorithm = { "SHA256" => {}, "SHA512" => {} }
      digests_by_entry.each do |entry_name, alg_map|
        by_algorithm["SHA256"][entry_name] = alg_map["SHA256"]
        by_algorithm["SHA512"][entry_name] = alg_map["SHA512"]
      end

      yaml_str = Psych.dump(by_algorithm)
      gzip_deterministic(yaml_str, epoch)
    end

    def gzip_deterministic(raw_bytes, epoch)
      buf   = StringIO.new("".b)
      level = @config.respond_to?(:compression_level) ? @config.compression_level : Zlib::DEFAULT_COMPRESSION
      gz    = Zlib::GzipWriter.new(buf, level)
      gz.mtime = epoch
      gz.write(raw_bytes)
      gz.close
      buf.string
    end

    def compute_digests(bytes)
      {
        "SHA256" => Digest::SHA256.hexdigest(bytes),
        "SHA512" => Digest::SHA512.hexdigest(bytes)
      }
    end

    def add_tar_bytes(tar_writer, name, mode, bytes)
      tar_writer.add_file_simple(name, mode, bytes.bytesize) do |io|
        io.write(bytes)
      end
    end

    def with_reproducible_epoch(epoch)
      EPOCH_MUTEX.synchronize do
        prev_env = ENV["SOURCE_DATE_EPOCH"]
        begin
          ENV["SOURCE_DATE_EPOCH"] = epoch.to_s
          Gem.instance_variable_set(:@source_date_epoch, nil) if Gem.instance_variable_defined?(:@source_date_epoch)
          yield
        ensure
          ENV["SOURCE_DATE_EPOCH"] = prev_env
          Gem.instance_variable_set(:@source_date_epoch, nil) if Gem.instance_variable_defined?(:@source_date_epoch)
        end
      end
    end
  end
end
