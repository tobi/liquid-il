# frozen_string_literal: true

require "shellwords"

task default: :test

desc "Run unit tests"
task :test do
  system "ruby -Ilib test/liquid_il_test.rb"
end

desc "Run the liquid-spec test suite"
task :spec do
  system "bash -c 'bundle exec liquid-spec run adapter.rb 2> >(grep -v \"missing extensions\" >&2)'"
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
  system "bundle exec liquid-spec inspect adapter.rb -n #{name.shellescape} 2>/dev/null | grep -v 'missing extensions'"
  puts

  # Extract template from spec output and run through liquidil eval
  require "yaml"
  spec_output = `bundle exec liquid-spec inspect adapter.rb -n #{name.shellescape} 2>/dev/null`
  if spec_output =~ /Template:\s*\n(.*?)(?=\n\s*Environment:|\n\s*Expected:|\Z)/m
    template = $1.strip
    puts "=" * 60
    puts "LiquidIL eval:"
    puts "=" * 60
    system "bin/liquidil eval #{template.shellescape}"
  end
end
