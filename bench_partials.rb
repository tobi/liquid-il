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

# Track totals for summary
totals = {
  liquid_ruby: { compile_time: 0, compile_allocs: 0, render_time: 0, render_allocs: 0 },
  liquid_il: { compile_time: 0, compile_allocs: 0, render_time: 0, render_allocs: 0 }
}
benchmark_count = 0

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

  # Measure compile time and allocations
  liquid_ruby_compile_allocs = measure_allocations do
    Liquid::Template.parse(template)
  end
  liquid_ruby_compile_time = measure { Liquid::Template.parse(template) }

  compiled_compile_allocs = measure_allocations do
    LiquidIL::Compiler::Ruby.compile(template, context: context)
  end
  compiled_compile_time = measure { LiquidIL::Compiler::Ruby.compile(template, context: context) }

  # Now create templates for rendering
  liquid_ruby_template = Liquid::Template.parse(template)
  compiled_template = LiquidIL::Compiler::Ruby.compile(template, context: context)

  # Warmup
  options[:warmup].times do
    liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) })
    compiled_template.render(env)
  end

  iterations = options[:iterations]

  # Measure render allocations (single iteration for accuracy)
  liquid_ruby_render_allocs = measure_allocations do
    liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) })
  end

  compiled_render_allocs = measure_allocations do
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

  liquid_ruby_render_us = (liquid_ruby_time / iterations) * 1_000_000
  compiled_render_us = (compiled_time / iterations) * 1_000_000
  render_speedup = liquid_ruby_render_us / compiled_render_us
  render_alloc_diff = liquid_ruby_render_allocs - compiled_render_allocs

  # Update totals
  totals[:liquid_ruby][:compile_time] += liquid_ruby_compile_time * 1_000_000
  totals[:liquid_ruby][:compile_allocs] += liquid_ruby_compile_allocs
  totals[:liquid_ruby][:render_time] += liquid_ruby_render_us
  totals[:liquid_ruby][:render_allocs] += liquid_ruby_render_allocs

  totals[:liquid_il][:compile_time] += compiled_compile_time * 1_000_000
  totals[:liquid_il][:compile_allocs] += compiled_compile_allocs
  totals[:liquid_il][:render_time] += compiled_render_us
  totals[:liquid_il][:render_allocs] += compiled_render_allocs

  benchmark_count += 1

  puts
  puts "  Compile (one-time):"
  puts "    %-20s %10.2f µs   %6d allocs" % ["liquid_ruby:", liquid_ruby_compile_time * 1_000_000, liquid_ruby_compile_allocs]
  puts "    %-20s %10.2f µs   %6d allocs" % ["liquid_il_compiled:", compiled_compile_time * 1_000_000, compiled_compile_allocs]
  puts
  puts "  Render (per call):"
  puts "    %-20s %10.2f µs/render   %6d allocs/render" % ["liquid_ruby:", liquid_ruby_render_us, liquid_ruby_render_allocs]
  puts "    %-20s %10.2f µs/render   %6d allocs/render" % ["liquid_il_compiled:", compiled_render_us, compiled_render_allocs]
  puts
  puts "    Render speedup: %.2fx faster" % render_speedup
  if render_alloc_diff > 0
    puts "    Render allocations: %d fewer (%.1f%%)" % [render_alloc_diff, (render_alloc_diff.to_f / liquid_ruby_render_allocs) * 100]
  elsif render_alloc_diff < 0
    puts "    Render allocations: %d more (+%.1f%%)" % [-render_alloc_diff, (-render_alloc_diff.to_f / liquid_ruby_render_allocs) * 100]
  else
    puts "    Render allocations: same"
  end
  puts
end

# Print summary
if benchmark_count > 0
  puts "=" * 80
  puts "Summary (#{benchmark_count} benchmarks)"
  puts "=" * 80
  puts

  # Compile totals (one-time cost)
  puts "Compile (one-time cost per template):"
  puts "  %-20s %10.2f µs total   %6d allocs total" % [
    "liquid_ruby:",
    totals[:liquid_ruby][:compile_time],
    totals[:liquid_ruby][:compile_allocs]
  ]
  puts "  %-20s %10.2f µs total   %6d allocs total" % [
    "liquid_il_compiled:",
    totals[:liquid_il][:compile_time],
    totals[:liquid_il][:compile_allocs]
  ]
  if totals[:liquid_ruby][:compile_time] < totals[:liquid_il][:compile_time]
    compile_speedup = totals[:liquid_il][:compile_time] / totals[:liquid_ruby][:compile_time]
    puts "  liquid_ruby compiles %.2fx faster (expected: IL does more work)" % compile_speedup
  else
    compile_speedup = totals[:liquid_ruby][:compile_time] / totals[:liquid_il][:compile_time]
    puts "  liquid_il compiles %.2fx faster" % compile_speedup
  end
  puts

  # Render totals (repeated cost)
  puts "Render (per-call cost, matters most for production):"
  puts "  %-20s %10.2f µs avg   %6d allocs avg" % [
    "liquid_ruby:",
    totals[:liquid_ruby][:render_time] / benchmark_count,
    totals[:liquid_ruby][:render_allocs] / benchmark_count
  ]
  puts "  %-20s %10.2f µs avg   %6d allocs avg" % [
    "liquid_il_compiled:",
    totals[:liquid_il][:render_time] / benchmark_count,
    totals[:liquid_il][:render_allocs] / benchmark_count
  ]
  render_speedup = totals[:liquid_ruby][:render_time] / totals[:liquid_il][:render_time]
  puts "  liquid_il renders %.2fx faster" % render_speedup
  puts

  # Break-even analysis
  puts "Break-even analysis:"
  compile_overhead = totals[:liquid_il][:compile_time] - totals[:liquid_ruby][:compile_time]
  render_savings = totals[:liquid_ruby][:render_time] - totals[:liquid_il][:render_time]
  if render_savings > 0
    break_even = (compile_overhead / render_savings).ceil
    puts "  Compile overhead: %.2f µs" % compile_overhead
    puts "  Render savings:   %.2f µs/render" % (render_savings / benchmark_count)
    puts "  Break-even after: ~%d renders (then pure profit)" % break_even
  else
    puts "  liquid_ruby is faster at rendering in these benchmarks"
  end
  puts
end

if options[:profile]
  puts "=" * 80
  puts "Profile files saved to tmp/"
  puts "=" * 80
end
