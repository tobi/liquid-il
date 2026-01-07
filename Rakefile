# frozen_string_literal: true

require "shellwords"

task default: :test

desc "Run unit tests"
task :test do
  system "ruby -Ilib test/liquid_il_test.rb"
end

ADAPTER = "spec/adapter.rb"

desc "Run the liquid-spec test suite"
task :spec do
  system "bash -c 'bundle exec liquid-spec run #{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run spec matrix comparing LiquidIL against reference implementations"
task :matrix do
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby,#{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run benchmarks comparing LiquidIL against reference implementations"
task :bench do
  system "bash -c 'bundle exec liquid-spec matrix --adapters=liquid_ruby,#{ADAPTER} -s benchmarks --bench 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run all tests"
task all: [:test, :spec]

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
  system "bundle exec liquid-spec inspect #{ADAPTER} -n #{name.shellescape} 2>/dev/null | grep -v 'missing extensions'"
  puts

  # Extract template from spec output and run through liquidil eval
  spec_output = `bundle exec liquid-spec inspect #{ADAPTER} -n #{name.shellescape} 2>/dev/null`
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
