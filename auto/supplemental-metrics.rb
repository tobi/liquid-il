# frozen_string_literal: true
# Supplemental metrics for autoresearch — code size, ISeq compile time, YJIT stats
# Run with: RUBY_YJIT_ENABLE=1 ruby -Ilib auto/supplemental-metrics.rb
# Outputs METRIC lines to stdout (same format as autoresearch.sh)

require "yaml"
require "liquid_il"

SPEC_DIR = File.join(`bundle info liquid-spec --path 2>/dev/null`.strip, "specs", "benchmarks")

# Load theme database for realistic data
db_path = File.join(SPEC_DIR, "_data", "theme_database.yml")
db = File.exist?(db_path) ? YAML.load_file(db_path, aliases: true) : {}

# Load all benchmark spec files
spec_files = Dir[File.join(SPEC_DIR, "*.yml")].reject { |f| f.end_with?("suite.yml") }
templates = []

spec_files.each do |file|
  data = YAML.load_file(file, aliases: true)
  next unless data["specs"]
  data["specs"].each do |spec|
    next unless spec["template"]
    templates << {
      name: spec["name"],
      source: spec["template"],
      environment: (spec["environment"] || {}).merge(db),
      filesystem: spec["filesystem"] || {},
    }
  end
end

# Build a simple file system for partials
class BenchFS
  def initialize(files)
    @files = {}
    files.each { |k, v| @files[k.sub(/\.liquid$/, "")] = v; @files[k] = v }
  end
  def read_template_file(name)
    @files[name] || @files["#{name}.liquid"] || ""
  end
end

# --- Measure code size across all templates ---
total_code_bytes = 0
total_code_lines = 0
total_iseq_compile_ns = 0
compiled_templates = []

templates.each do |t|
  fs = BenchFS.new(t[:filesystem])
  ctx = LiquidIL::Context.new(file_system: fs)
  begin
    result = LiquidIL::Compiler::Structured.compile(t[:source], context: ctx)
    src = result.compiled_source
    total_code_bytes += src.bytesize
    total_code_lines += src.count("\n")
    compiled_templates << { name: t[:name], result: result, env: t[:environment] }
  rescue => e
    # Skip templates that fail to compile (missing features etc.)
    next
  end
end

# --- Measure ISeq compile time ---
# Clear the ISeq cache to force fresh compilation
LiquidIL::StructuredCompiler.class_variable_set(:@@iseq_cache, {}) rescue nil

iseq_times = []
templates.each do |t|
  fs = BenchFS.new(t[:filesystem])
  ctx = LiquidIL::Context.new(file_system: fs)
  begin
    result = LiquidIL::Compiler::Structured.compile(t[:source], context: ctx)
    src = result.compiled_source

    # Time ISeq compilation specifically
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    iseq = RubyVM::InstructionSequence.compile(src, "(bench_iseq)")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start
    iseq_times << elapsed
  rescue
    next
  end
end
total_iseq_compile_us = (iseq_times.sum / 1000.0).round

# --- Warm up YJIT for stats ---
compiled_templates.each do |t|
  50.times { t[:result].render(t[:env]) rescue nil }
end

# --- YJIT stats ---
yjit_inline = 0
yjit_outlined = 0
yjit_blocks = 0
yjit_invalidations = 0
yjit_side_exits = 0
if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  stats = RubyVM::YJIT.runtime_stats
  yjit_inline = stats[:inline_code_size] || 0
  yjit_outlined = stats[:outlined_code_size] || 0
  yjit_blocks = stats[:compiled_block_count] || 0
  yjit_invalidations = stats[:invalidation_count] || 0
  # side_exit_count was renamed/moved in different Ruby versions
  yjit_side_exits = stats[:side_exit_count] || stats[:exec_instruction] || 0
end

# --- Output METRIC lines ---
puts "METRIC codegen_bytes=#{total_code_bytes}"
puts "METRIC codegen_lines=#{total_code_lines}"
puts "METRIC iseq_compile_µs=#{total_iseq_compile_us}"
puts "METRIC yjit_inline_bytes=#{yjit_inline}"
puts "METRIC yjit_blocks=#{yjit_blocks}"
puts "METRIC yjit_invalidations=#{yjit_invalidations}"
