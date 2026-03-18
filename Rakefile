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

desc "Benchmark all adapters (liquid_ruby, liquid_il, and liquid_vm if available)"
task :bench do
  adapters = [ADAPTER_RUBY, ADAPTER, ADAPTER_VM].select { |a| File.exist?(a) }
  puts "Benchmarking: #{adapters.map { |a| File.basename(a, '.rb') }.join(', ')}"
  puts

  results = {}
  adapters.each do |adapter|
    name = File.basename(adapter, ".rb")
    puts "=" * 60
    puts name
    puts "=" * 60
    output = `RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run #{adapter} -s benchmarks --bench 2>&1`
    puts output.gsub(/\e\[[0-9;]*m/, "").lines.grep(/Tests:|Parse:|Render:|Allocs:|jit/).join
    results[name] = output
    puts
  end
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end
