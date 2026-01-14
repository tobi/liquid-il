# frozen_string_literal: true

require "shellwords"

task default: :test

# Unit test files
TEST_FILES = %w[
  test/liquid_il_test.rb
  test/ruby_compiler_test.rb
  test/register_allocation_test.rb
  test/optimization_passes_test.rb
  test/error_handling_test.rb
].freeze

# Optimization passes (0-19)
OPTIMIZATION_PASSES = (0..19).to_a.freeze

desc "Run comprehensive test suite"
task :test do
  failed = false

  # 1. Run unit tests
  puts "\n#{"=" * 60}"
  puts "Running unit tests"
  puts "=" * 60
  TEST_FILES.each do |test_file|
    puts "\n--- #{test_file} ---"
    unless system("bundle exec ruby -Ilib #{test_file}")
      failed = true
      puts "FAILED: #{test_file}"
    end
  end

  # 2. Run unit tests with each optimization pass individually
  puts "\n#{"=" * 60}"
  puts "Testing each optimization pass individually"
  puts "=" * 60
  OPTIMIZATION_PASSES.each do |pass|
    puts "\n--- Pass #{pass} ---"
    unless system({ "LIQUID_PASSES" => pass.to_s }, "bundle exec ruby -Ilib test/liquid_il_test.rb")
      failed = true
      puts "FAILED: Pass #{pass}"
    end
  end

  # 3. Run liquid-spec for VM adapter
  puts "\n#{"=" * 60}"
  puts "Running liquid-spec: VM (#{ADAPTER_VM})"
  puts "=" * 60
  unless system("bash -c 'bundle exec liquid-spec run #{ADAPTER_VM} 2> >(grep -v \"missing extensions\" >&2)'")
    failed = true
    puts "FAILED: liquid-spec VM"
  end

  # 4. Run liquid-spec for compiled adapter
  puts "\n#{"=" * 60}"
  puts "Running liquid-spec: Compiled (#{ADAPTER_COMPILED})"
  puts "=" * 60
  unless system("bash -c 'bundle exec liquid-spec run #{ADAPTER_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'")
    failed = true
    puts "FAILED: liquid-spec Compiled"
  end

  # 5. Run liquid-spec for optimized+compiled adapter
  puts "\n#{"=" * 60}"
  puts "Running liquid-spec: Optimized+Compiled (#{ADAPTER_OPTIMIZED_COMPILED})"
  puts "=" * 60
  unless system("bash -c 'bundle exec liquid-spec run #{ADAPTER_OPTIMIZED_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'")
    failed = true
    puts "FAILED: liquid-spec Optimized+Compiled"
  end

  if failed
    puts "\n#{"=" * 60}"
    puts "SOME TESTS FAILED"
    puts "=" * 60
    exit 1
  else
    puts "\n#{"=" * 60}"
    puts "ALL TESTS PASSED"
    puts "=" * 60
  end
end

desc "Run unit tests only (quick)"
task :unit do
  TEST_FILES.each do |test_file|
    system("bundle exec ruby -Ilib #{test_file}") || exit(1)
  end
end

ADAPTER_VM = "spec/liquid_il.rb"
ADAPTER_OPTIMIZED = "spec/liquid_il_optimized.rb"
ADAPTER_COMPILED = "spec/liquid_il_compiled.rb"
ADAPTER_OPTIMIZED_COMPILED = "spec/liquid_il_optimized_compiled.rb"

desc "Run the liquid-spec test suite"
task :spec do
  system "bash -c 'bundle exec liquid-spec run #{ADAPTER_VM} 2> >(grep -v \"missing extensions\" >&2)'"
  system "bash -c 'bundle exec liquid-spec run #{ADAPTER_OPTIMIZED_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run spec matrix comparing LiquidIL against reference implementations"
task :matrix do
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby,#{ADAPTER_VM},#{ADAPTER_COMPILED},#{ADAPTER_OPTIMIZED_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run benchmarks comparing LiquidIL against reference implementations"
task :bench do
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby,#{ADAPTER_VM},#{ADAPTER_COMPILED},#{ADAPTER_OPTIMIZED_COMPILED} -s benchmarks --bench 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run partials benchmarks (local)"
task :bench_partials do
  system "bundle exec ruby bench_partials.rb"
end

desc "Run unit tests with specific optimization passes"
task :test_pass, [:passes] do |_t, args|
  passes = args[:passes] || "*"
  puts "Running tests with LIQUID_PASSES=#{passes.inspect}"
  system({ "LIQUID_PASSES" => passes }, "bundle exec ruby -Ilib test/liquid_il_test.rb")
end

desc "Run spec with specific optimization passes"
task :spec_pass, [:passes] do |_t, args|
  passes = args[:passes] || "*"
  puts "Running spec with LIQUID_PASSES=#{passes.inspect}"
  system({ "LIQUID_PASSES" => passes }, "bash -c 'bundle exec liquid-spec run #{ADAPTER_OPTIMIZED_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'")
end

desc "Run spec with each optimization pass individually"
task :spec_each_pass do
  OPTIMIZATION_PASSES.each do |pass|
    puts "\n" + "=" * 60
    puts "Testing with only pass #{pass} enabled"
    puts "=" * 60
    system({ "LIQUID_PASSES" => pass.to_s }, "bash -c 'bundle exec liquid-spec run #{ADAPTER_OPTIMIZED_COMPILED} 2> >(grep -v \"missing extensions\" >&2)'")
  end
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end

desc "Inspect a specific test - shows spec details and IL output"
task :inspect, [:name] do |_t, args|
  name = args[:name]
  unless name
    puts "Usage: rake inspect[test_name]"
    puts "Example: rake inspect[test_case_with_invalid_expression]"
    exit 1
  end

  puts "=" * 60
  puts "Spec details:"
  puts "=" * 60
  system "bundle exec liquid-spec inspect #{ADAPTER_VM} -n #{name.shellescape} 2>/dev/null | grep -v 'missing extensions'"
  puts

  # Extract template from spec output and run through liquidil eval
  spec_output = `bundle exec liquid-spec inspect #{ADAPTER_VM} -n #{name.shellescape} 2>/dev/null`
  # Strip ANSI color codes
  spec_output = spec_output.gsub(/\e\[[0-9;]*m/, '')

  # Parse the template between "Template:" and "Environment:" or "Expected:"
  template = nil
  in_template = false
  lines = []
  spec_output.each_line do |line|
    if line =~ /^Template:/
      in_template = true
      next
    elsif in_template && line =~ /^(Environment|Expected):/
      break
    elsif in_template
      lines << line
    end
  end

  if lines.any?
    # Remove leading whitespace that's common to all lines
    template = lines.map { |l| l.rstrip }.join("\n").strip
    puts "=" * 60
    puts "LiquidIL IL output:"
    puts "=" * 60
    system "bin/liquidil eval #{template.shellescape}"
  else
    puts "Could not extract template from spec"
  end
end
