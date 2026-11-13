# frozen_string_literal: true

require "stringio"
require "zlib"

module RubyToFaster
  module Plugins
    # Pre-compresses staged text/web assets (`.js`, `.mjs`, `.css`, `.html`, `.svg`, `.json`)
    # into deterministic `.gz` sidecar entries inside the `.gem` so `RubyToFaster::Middleware`
    # can serve gzipped responses with zero runtime CPU overhead.
    class Precompress
      COMPRESSIBLE_EXT = /\.(?:js|mjs|css|html|svg|json|txt|xml)\z/i

      def initialize(min_bytes: 256, epoch: Packager::DEFAULT_EPOCH)
        @min_bytes = min_bytes
        @epoch     = epoch
      end

      def generate_bundle(entries, config)
        epoch = config.source_date_epoch || (config.reproducible ? @epoch : Time.now.to_i)
        additions = {}

        entries.each do |gem_path, entry|
          next unless gem_path.start_with?("public/") || gem_path.include?("/public/")
          next unless COMPRESSIBLE_EXT.match?(gem_path)
          next if entries.key?("#{gem_path}.gz")

          raw = entry.bytes
          next if raw.bytesize < @min_bytes

          gz_bytes = compress_bytes(raw, epoch)
          # Only keep pre-compressed sidecar when smaller than original
          next unless gz_bytes.bytesize < raw.bytesize

          gz_path = "#{gem_path}.gz"
          additions[gz_path] = PackageEntry.new(
            gem_path: gz_path,
            source_path: nil,
            content: gz_bytes,
            mode: 0o644,
            executable: false
          )
        end

        entries.merge!(additions)
      end

      private

      def compress_bytes(raw_bytes, epoch)
        buf = StringIO.new("".b)
        gz  = Zlib::GzipWriter.new(buf, Zlib::BEST_COMPRESSION)
        gz.mtime = epoch
        gz.write(raw_bytes)
        gz.close
        buf.string
      end
    end
  end
end
