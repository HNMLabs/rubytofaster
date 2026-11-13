# frozen_string_literal: true

require "etc"

module RubyToFaster
  # Turborepo / Nx / Angular-inspired topological monorepo workspace runner for multi-gem repositories.
  class Workspace
    DEFAULT_PATTERNS = %w[gems/* packages/* plugins/* apps/*].freeze

    Member = Struct.new(:name, :dir, :spec, :script_path, :internal_deps, keyword_init: true)
    WorkspaceResult = Struct.new(:waves, :results, :total_ms, keyword_init: true) do
      def cache_hits
        results.count(&:cache_hit)
      end
    end

    def initialize(root_dir: Dir.pwd, patterns: nil, parallel_jobs: nil, incremental: true)
      @root_dir      = File.expand_path(root_dir)
      @patterns      = patterns || DEFAULT_PATTERNS
      @parallel_jobs = [parallel_jobs || Etc.nprocessors, 1].max
      @incremental   = incremental
    end

    def discover_members
      dirs = []
      @patterns.each do |glob|
        Dir.glob(File.join(@root_dir, glob)).sort.each do |candidate|
          next unless File.directory?(candidate)
          next unless has_gem_target?(candidate)

          dirs << File.expand_path(candidate)
        end
      end

      members_by_name = {}
      raw_members = dirs.uniq.map do |dir|
        script = CLI::DEFAULT_SCRIPT_NAMES.map { |n| File.join(dir, n) }.find { |p| File.file?(p) }
        cfg = script ? RubyToFaster.load_script_config(script) : Config.new(root_dir: dir)
        spec, = FileResolver.new(cfg).load_gemspec
        member = Member.new(name: spec.name, dir: dir, spec: spec, script_path: script, internal_deps: [])
        members_by_name[spec.name] = member
        member
      end

      raw_members.each do |m|
        dep_names = m.spec.dependencies.map(&:name)
        m.internal_deps = dep_names.select { |d| members_by_name.key?(d) && d != m.name }.sort
      end

      raw_members
    end

    # Computes topological execution waves using Kahn's algorithm.
    # Gems within the same wave have zero unmet dependencies and build concurrently.
    def plan_waves(members = discover_members)
      raise ConfigError, "No workspace gem packages found under #{@root_dir}" if members.empty?

      by_name   = members.each_with_object({}) { |m, h| h[m.name] = m }
      in_degree = {}
      dependents = Hash.new { |h, k| h[k] = [] }

      members.each do |m|
        in_degree[m.name] = m.internal_deps.size
        m.internal_deps.each { |dep| dependents[dep] << m.name }
      end

      waves = []
      remaining = in_degree.dup

      until remaining.empty?
        ready_names = remaining.select { |_, deg| deg.zero? }.keys.sort
        if ready_names.empty?
          cycle_nodes = remaining.keys.sort.join(" -> ")
          raise ConfigError, "Circular gem dependency detected in workspace: #{cycle_nodes}"
        end

        waves << ready_names.map { |n| by_name[n] }
        ready_names.each do |done_name|
          remaining.delete(done_name)
          dependents[done_name].each do |child|
            remaining[child] -= 1 if remaining.key?(child)
          end
        end
      end

      waves
    end

    def build_all
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      waves = plan_waves
      all_results = []

      waves.each do |wave_members|
        wave_results = build_wave_parallel(wave_members)
        all_results.concat(wave_results)
      end

      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - t0).round(2)
      WorkspaceResult.new(
        waves: waves.map { |w| w.map(&:name) },
        results: all_results,
        total_ms: elapsed
      )
    end

    private

    def has_gem_target?(dir)
      CLI::DEFAULT_SCRIPT_NAMES.any? { |n| File.file?(File.join(dir, n)) } ||
        !Dir.glob(File.join(dir, "*.gemspec")).empty?
    end

    def build_wave_parallel(wave_members)
      queue   = Queue.new
      wave_members.each { |m| queue << m }
      results = []
      errors  = []
      mutex   = Mutex.new

      workers = Array.new([@parallel_jobs, wave_members.size].min) do
        Thread.new do
          loop do
            member = begin
              queue.pop(true)
            rescue ThreadError
              break
            end

            begin
              cfg = if member.script_path
                      RubyToFaster.load_script_config(member.script_path)
                    else
                      Config.new(root_dir: member.dir)
                    end
              cfg.incremental = @incremental
              res = Compiler.new(cfg).run
              mutex.synchronize { results << res }
            rescue StandardError => e
              mutex.synchronize { errors << e }
            end
          end
        end
      end

      workers.each(&:join)
      raise errors.first unless errors.empty?

      results.sort_by(&:gem_name)
    end
  end
end
