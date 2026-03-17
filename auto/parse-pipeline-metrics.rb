# frozen_string_literal: true
# Parse pipeline breakdown metrics
# Outputs METRIC lines for each stage: lex_parse_il_µs, structured_compile_µs, iseq_eval_µs
# Run with: RUBY_YJIT_ENABLE=1 ruby -Ilib auto/parse-pipeline-metrics.rb

require "yaml"
require "liquid_il"

SPEC_DIR = File.join(`bundle info liquid-spec --path 2>/dev/null`.strip, "specs", "benchmarks")
db_path = File.join(SPEC_DIR, "_data", "theme_database.yml")
db = File.exist?(db_path) ? YAML.load_file(db_path, aliases: true) : {}

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
      filesystem: spec["filesystem"] || {},
    }
  end
end

class BenchFS
  def initialize(files)
    @files = {}
    files.each { |k, v| @files[k.sub(/\.liquid$/, "")] = v; @files[k] = v }
  end
  def read_template_file(name)
    @files[name] || @files["#{name}.liquid"] || ""
  end
end

OPTS = LiquidIL::Compiler::Structured::STRUCTURED_DEFAULTS

# Warmup (populates ISeq cache)
templates.each do |t|
  fs = BenchFS.new(t[:filesystem])
  ctx = LiquidIL::Context.new(file_system: fs)
  5.times { ctx.parse(t[:source]) rescue nil }
end

# Measure each stage separately, 5 runs for stability
stage_times = Hash.new(0)
runs = 5

runs.times do
  templates.each do |t|
    fs = BenchFS.new(t[:filesystem])
    ctx = LiquidIL::Context.new(file_system: fs)

    # Stage 1: Lex + Parse + IL + Optimize + Link
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    compiler = LiquidIL::Compiler.new(t[:source], **OPTS.merge(file_system: fs))
    result = compiler.compile
    stage_times[:lex_parse_il] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - s

    # Stage 2: Structured compile (IL → Ruby source)
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    sc = LiquidIL::StructuredCompiler.new(
      result[:instructions],
      spans: result[:spans],
      template_source: t[:source],
      context: ctx
    )
    compiled = sc.compile
    stage_times[:structured_compile] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - s

    # Stage 3: ISeq eval (load from binary cache)
    src = compiled.source
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    key = src.hash
    cache = LiquidIL::StructuredCompiler.class_variable_get(:@@iseq_cache)
    if (bin = cache[key])
      RubyVM::InstructionSequence.load_from_binary(bin).eval
    else
      iseq = RubyVM::InstructionSequence.compile(src, "(bench)")
      cache[key] = iseq.to_binary
      iseq.eval
    end
    stage_times[:iseq_eval] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - s
  end
end

# Output per-stage averages
stage_times.each do |stage, ns|
  us = (ns / (runs * 1000.0)).round
  puts "METRIC #{stage}_µs=#{us}"
end
