# frozen_string_literal: true

require "shellwords"

task default: :test

ADAPTER = "spec/liquid_il_structured.rb"
TEST_FILES = %w[
  test/liquid_il_test.rb
  test/structured_compiler_test.rb
  test/optimization_passes_test.rb
  test/error_handling_test.rb
].freeze

require_relative "lib/liquid_il/passes"

desc "Run full test suite"
task :test do
  # Unit tests
  puts "\n#{"=" * 60}\nRunning unit tests\n#{"=" * 60}"
  TEST_FILES.each do |f|
    puts "\n--- #{f} ---"
    system("bundle exec ruby -Ilib #{f}") || exit(1)
  end

  # liquid-spec
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
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby --adapter=#{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Benchmark against reference Liquid"
task :bench do
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby --adapter=#{ADAPTER} -s benchmarks --bench 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end
