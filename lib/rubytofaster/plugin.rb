# frozen_string_literal: true

module RubyToFaster
  # Minimalist Vite/Rollup-inspired plugin runner for gem build pipelines.
  class PluginRunner
    def initialize(config)
      @plugins = config.plugins
      @hooks   = config.hooks
    end

    def has_transforms?
      !@hooks[:transform].empty? || @plugins.any? { |p| p.respond_to?(:transform) }
    end

    # Returns true if any inline closure hook or un-fingerprinted custom plugin mutates bundle entries,
    # requiring eager execution prior to Merkle cache lookup.
    def has_dynamic_hooks?
      return true unless @hooks[:transform].empty? && @hooks[:generate_bundle].empty?

      @plugins.any? do |p|
        mutates = p.respond_to?(:transform) || p.respond_to?(:generate_bundle)
        mutates && !p.respond_to?(:cache_fingerprint)
      end
    end

    def cache_fingerprints
      @plugins.map do |p|
        p.respond_to?(:cache_fingerprint) ? p.cache_fingerprint.to_s : p.class.name.to_s
      end
    end

    def run_before_resolve(context)
      @plugins.each do |plugin|
        plugin.before_resolve(context) if plugin.respond_to?(:before_resolve)
      end
      @hooks[:before_resolve].each { |fn| fn.call(context) }
    end

    # Allows plugins/hooks to transform file contents in-memory before tar packaging.
    # Returning a String replaces the packaged bytes; returning nil keeps original bytes.
    def run_transform(gem_path, content)
      current = content
      @plugins.each do |plugin|
        next unless plugin.respond_to?(:transform)

        replaced = plugin.transform(gem_path, current)
        current = replaced if replaced.is_a?(String)
      end
      @hooks[:transform].each do |fn|
        replaced = fn.call(gem_path, current)
        current = replaced if replaced.is_a?(String)
      end
      current
    end

    def run_generate_bundle(entries_map, context)
      @plugins.each do |plugin|
        plugin.generate_bundle(entries_map, context) if plugin.respond_to?(:generate_bundle)
      end
      @hooks[:generate_bundle].each { |fn| fn.call(entries_map, context) }
    end

    def run_after_package(result)
      @plugins.each do |plugin|
        plugin.after_package(result) if plugin.respond_to?(:after_package)
      end
      @hooks[:after_package].each { |fn| fn.call(result) }
    end
  end
end
