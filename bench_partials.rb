# frozen_string_literal: true

require "liquid"
require_relative "lib/liquid_il"
require "yaml"
require "json"
require "optparse"

# Parse command-line options
options = {
  profile: nil,
  profile_benchmark: nil,
  iterations: 1000,
  warmup: 5
}

OptionParser.new do |opts|
  opts.banner = "Usage: bench_partials.rb [options]"

  opts.on("--profile MODE", "Enable profiling (stackprof, memory)") do |mode|
    options[:profile] = mode.to_sym
  end

  opts.on("--profile-benchmark NAME", "Profile only this benchmark") do |name|
    options[:profile_benchmark] = name
  end

  opts.on("--iterations N", Integer, "Number of iterations (default: 1000)") do |n|
    options[:iterations] = n
  end

  opts.on("--warmup N", Integer, "Number of warmup iterations (default: 5)") do |n|
    options[:warmup] = n
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# Load profiler gems if needed
case options[:profile]
when :stackprof
  require "stackprof"
when :memory
  require "memory_profiler"
end

def measure
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

def measure_allocations
  GC.disable
  before = GC.stat(:total_allocated_objects)
  yield
  after = GC.stat(:total_allocated_objects)
  GC.enable
  after - before
end

def run_with_profile(profile_mode, name, &block)
  case profile_mode
  when :stackprof
    profile_path = "tmp/stackprof_#{name}.dump"
    StackProf.run(mode: :wall, out: profile_path, raw: true, &block)
    puts "  Stackprof saved to: #{profile_path}"
    puts "  View with: bundle exec stackprof #{profile_path} --text"
    puts "  Flamegraph: bundle exec stackprof #{profile_path} --d3-flamegraph > tmp/#{name}_flamegraph.html"
  when :memory
    report = MemoryProfiler.report(&block)
    profile_path = "tmp/memory_#{name}.txt"
    report.pretty_print(to_file: profile_path, scale_bytes: true)
    puts "  Memory profile saved to: #{profile_path}"
    puts "  Total allocated: #{report.total_allocated_memsize} bytes"
    puts "  Total retained: #{report.total_retained_memsize} bytes"
    puts "  Allocated objects: #{report.total_allocated}"
  else
    yield
  end
end

# Load specs from partials.yml
specs = YAML.load_file("benchmarks/partials.yml")["specs"]

class BenchFS
  def initialize(files)
    @files = files
  end

  def read(name)
    @files[name] || ""
  end

  def read_template_file(name)
    @files[name] || ""
  end
end

# Ensure tmp directory exists for profiler output
Dir.mkdir("tmp") unless Dir.exist?("tmp")

puts "=" * 80
puts "Partials Benchmark"
puts "=" * 80
puts "Iterations: #{options[:iterations]}, Warmup: #{options[:warmup]}"
puts "Profile mode: #{options[:profile] || 'none'}"
puts

specs.each do |spec|
  name = spec["name"]
  template = spec["template"]
  env = spec["environment"]
  env = env.is_a?(String) ? JSON.parse(env.gsub("=>", ":")) : env
  fs = spec["filesystem"] || {}

  # Skip if profiling a specific benchmark and this isn't it
  if options[:profile_benchmark] && name != options[:profile_benchmark]
    next
  end

  puts name
  puts "-" * 50

  context = LiquidIL::Context.new(file_system: BenchFS.new(fs))

  # Compile with liquid_ruby (reference)
  liquid_ruby_template = Liquid::Template.parse(template)

  # Compile with liquid_il_compiled
  compiled_template = LiquidIL::Compiler::Ruby.compile(template, context: context)

  # Warmup
  options[:warmup].times do
    liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) })
    compiled_template.render(env)
  end

  iterations = options[:iterations]

  # Measure allocations (single iteration for accuracy)
  liquid_ruby_allocs = measure_allocations do
    liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) })
  end

  compiled_allocs = measure_allocations do
    compiled_template.render(env)
  end

  # Benchmark render timing
  should_profile = options[:profile] && (!options[:profile_benchmark] || name == options[:profile_benchmark])

  puts "  liquid_ruby:"
  liquid_ruby_time = nil
  run_with_profile(should_profile ? options[:profile] : nil, "#{name}_liquid_ruby") do
    liquid_ruby_time = measure do
      iterations.times { liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) }) }
    end
  end

  puts "  liquid_il_compiled:"
  compiled_time = nil
  run_with_profile(should_profile ? options[:profile] : nil, "#{name}_liquid_il") do
    compiled_time = measure do
      iterations.times { compiled_template.render(env) }
    end
  end

  liquid_ruby_us = (liquid_ruby_time / iterations) * 1_000_000
  compiled_us = (compiled_time / iterations) * 1_000_000
  speedup = liquid_ruby_us / compiled_us
  alloc_diff = liquid_ruby_allocs - compiled_allocs

  puts
  puts "  Results:"
  puts "    %-20s %10.2f µs/render   %6d allocs/render" % ["liquid_ruby:", liquid_ruby_us, liquid_ruby_allocs]
  puts "    %-20s %10.2f µs/render   %6d allocs/render" % ["liquid_il_compiled:", compiled_us, compiled_allocs]
  puts
  puts "    Speedup: %.2fx faster" % speedup
  if alloc_diff > 0
    puts "    Allocations: %d fewer (%.1f%%)" % [alloc_diff, (alloc_diff.to_f / liquid_ruby_allocs) * 100]
  elsif alloc_diff < 0
    puts "    Allocations: %d more (+%.1f%%)" % [-alloc_diff, (-alloc_diff.to_f / liquid_ruby_allocs) * 100]
  else
    puts "    Allocations: same"
  end
  puts
end

if options[:profile]
  puts "=" * 80
  puts "Profile files saved to tmp/"
  puts "=" * 80
end
