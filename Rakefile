# frozen_string_literal: true

require "shellwords"

task default: :test

ADAPTER = "spec/liquid_il.rb"
ADAPTER_VM = "spec/liquid_vm.rb"
ADAPTER_RUBY = "spec/liquid_ruby_bench.rb"
TEST_FILES = %w[
  test/liquid_il_test.rb
  test/ruby_compiler_test.rb
  test/optimization_passes_test.rb
  test/error_handling_test.rb
  test/dynamic_partials_runtime_test.rb
  test/dynamic_partials_performance_test.rb
  test/iseq_cache_test.rb
  test/iseq_persistence_test.rb
].freeze

require_relative "lib/liquid_il/passes"

desc "Run full test suite"
task :test do
  puts "\n#{"=" * 60}\nRunning unit tests\n#{"=" * 60}"
  TEST_FILES.each do |f|
    puts "\n--- #{f} ---"
    system("bundle exec ruby -Ilib #{f}") || exit(1)
  end

  puts "\n#{"=" * 60}\nRunning liquid-spec\n#{"=" * 60}"
  system("bash -c 'bundle exec liquid-spec run #{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'") || exit(1)

  puts "\n#{"=" * 60}\nALL TESTS PASSED\n#{"=" * 60}"
end

desc "Run unit tests only"
task :unit do
  TEST_FILES.each do |f|
    system("bundle exec ruby -Ilib #{f}") || exit(1)
  end
end

desc "Run liquid-spec"
task :spec do
  system "bash -c 'bundle exec liquid-spec run #{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run spec matrix against reference Liquid"
task :matrix do
  adapters = "--adapters=liquid_ruby --adapter=#{ADAPTER}"
  adapters += " --adapter=#{ADAPTER_VM}" if File.exist?(ADAPTER_VM)
  system "bash -c 'bundle exec liquid-spec matrix #{adapters} --no-max-failures 2> >(grep -v \"missing extensions\" >&2)'"
end

# Benchmarks run through liquid-spec's harness (GC-disciplined timing, real
# percentiles, allocs). The adapter implements the compiled-artifact protocol
# (LiquidSpec.dump_artifact / load_artifact), so every bench also reports the
# artifact stage: payload bytes, cold load, load+first-render, steady-state
# load — with a dump → load → render roundtrip check per spec.
desc "Benchmark vs reference liquid (liquid-spec suite, warm + artifact load, comparison)"
task :bench do
  system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER}") || exit(1)
end

namespace :bench do
  desc "Benchmark the local partial-heavy suite (specs/partials) vs reference liquid"
  task :partials do
    system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER} -s partials") || exit(1)
  end

  desc "Cold-path stage breakdown: envelope decode / ISeq load / eval / first render (validated vs reference gem)"
  task :cold do
    system("RUBY_YJIT_ENABLE=1 bundle exec ruby bench/cold_bench.rb") || exit(1)
  end
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end
