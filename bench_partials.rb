# frozen_string_literal: true

require "liquid"
require_relative "lib/liquid_il"
require "yaml"
require "json"

def measure
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
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

  # For Liquid::Template compatibility
  def read_template_file(name)
    @files[name] || ""
  end
end

puts "=" * 70
puts "Partials Benchmark"
puts "=" * 70
puts

specs.each do |spec|
  name = spec["name"]
  template = spec["template"]
  env = spec["environment"]
  env = env.is_a?(String) ? JSON.parse(env.gsub("=>", ":")) : env
  fs = spec["filesystem"] || {}

  puts "#{name}"
  puts "-" * 40

  context = LiquidIL::Context.new(file_system: BenchFS.new(fs))

  # Compile with liquid_ruby (reference)
  liquid_ruby_template = Liquid::Template.parse(template)

  # Compile with liquid_il_compiled
  compiled_template = LiquidIL::Compiler::Ruby.compile(template, context: context)

  # Warmup
  5.times do
    liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) })
    compiled_template.render(env)
  end

  iterations = 1000

  # Benchmark render
  liquid_ruby_time = measure do
    iterations.times { liquid_ruby_template.render(env, registers: { file_system: BenchFS.new(fs) }) }
  end

  compiled_time = measure do
    iterations.times { compiled_template.render(env) }
  end

  liquid_ruby_us = (liquid_ruby_time / iterations) * 1_000_000
  compiled_us = (compiled_time / iterations) * 1_000_000
  speedup = liquid_ruby_us / compiled_us

  puts "  liquid_ruby:     #{liquid_ruby_us.round(2)} µs/render"
  puts "  liquid_il_compiled: #{compiled_us.round(2)} µs/render"
  puts "  speedup: #{speedup.round(2)}x"
  puts
end
