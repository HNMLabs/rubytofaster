# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = true
end

desc "Build rubytofaster.gem using RubyToFaster itself (dogfooding)"
task :build_self do
  sh RbConfig.ruby, "-Ilib", "gem.build.rb"
end

desc "Measure real hardware build speed scores and render assets/benchmarks.gif + assets/benchmarks.json"
task :bench_gif do
  sh RbConfig.ruby, "-Ilib", "exe/rtf", "bench", "-n", "10", "-w", "2",
     "--gif", "assets/benchmarks.gif",
     "--json-out", "assets/benchmarks.json"
end

task default: :test
