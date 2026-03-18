#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Quick syntax check on key files (<0.5s total)
for f in lib/liquid_il/lexer.rb lib/liquid_il/parser.rb lib/liquid_il/il.rb lib/liquid_il/ruby_compiler.rb lib/liquid_il/compiler.rb lib/liquid_il/passes.rb; do
  ruby -c "$f" > /dev/null 2>&1 || { echo "SYNTAX ERROR in $f" >&2; echo "METRIC parse_µs=0"; echo "METRIC render_µs=0"; exit 1; }
done

# Run benchmark with YJIT
RESULTS=$(RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run spec/liquid_il.rb -s benchmarks --bench 2>&1)

# Check for failures
if echo "$RESULTS" | grep -q "0 passed"; then
  echo "METRIC parse_µs=0"
  echo "METRIC render_µs=0"
  exit 1
fi

# Strip ANSI codes once
CLEAN=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g')

# Extract parse and render values
eval "$(ruby -e '
lines = STDIN.read
parse_line = lines[/Parse:.*total/]
render_line = lines[/Render:.*total/]

parse_val = parse_line[/([0-9.]+)\s*ms\s*total/, 1].to_f
if render_line =~ /([0-9.]+)\s*ms\s*total/
  render_us = ($1.to_f * 1000).round
elsif render_line =~ /([0-9.]+)\s*.s\s*total/
  render_us = $1.to_f.round
end
parse_us = (parse_val * 1000).round

puts "PARSE_US=#{parse_us}"
puts "RENDER_US=#{render_us}"
' <<< "$CLEAN")"

# Extract alloc counts
ALLOCS=$(echo "$CLEAN" | grep "Allocs:")
PARSE_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ parse' | grep -oE '[0-9,]+' | tr -d ',')
RENDER_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ render' | grep -oE '[0-9,]+' | tr -d ',')

echo "METRIC parse_µs=${PARSE_US}"
echo "METRIC render_µs=${RENDER_US}"
echo "METRIC parse_allocs=${PARSE_ALLOCS}"
echo "METRIC render_allocs=${RENDER_ALLOCS}"

# Parse pipeline breakdown — measures each stage independently
PIPELINE=$(RUBY_YJIT_ENABLE=1 ruby -Ilib -e '
require "yaml"
require "liquid_il"

SPEC_DIR = File.join(`bundle info liquid-spec --path 2>/dev/null`.strip, "specs", "benchmarks")
spec_files = Dir[File.join(SPEC_DIR, "*.yml")].reject { |f| f.end_with?("suite.yml") }
templates = []
spec_files.each do |file|
  data = YAML.load_file(file, aliases: true)
  next unless data["specs"]
  data["specs"].each do |spec|
    next unless spec["template"]
    templates << { source: spec["template"], filesystem: spec["filesystem"] || {} }
  end
end

class BenchFS
  def initialize(files); @files = {}; files.each { |k, v| @files[k.sub(/\.liquid$/, "")] = v; @files[k] = v }; end
  def read_template_file(name); @files[name] || @files["#{name}.liquid"] || ""; end
end

OPTS = LiquidIL::Compiler::Ruby::RUBY_DEFAULTS

# Warmup (populates ISeq cache)
templates.each { |t| fs = BenchFS.new(t[:filesystem]); ctx = LiquidIL::Context.new(file_system: fs); 5.times { ctx.parse(t[:source]) rescue nil } }

stage_times = Hash.new(0)
5.times do
  templates.each do |t|
    fs = BenchFS.new(t[:filesystem])
    ctx = LiquidIL::Context.new(file_system: fs)

    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    compiler = LiquidIL::Compiler.new(t[:source], **OPTS.merge(file_system: fs))
    result = compiler.compile
    stage_times[:lex_parse_il] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - s

    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    sc = LiquidIL::RubyCompiler.new(result[:instructions], spans: result[:spans], template_source: t[:source], context: ctx)
    compiled = sc.compile
    stage_times[:ruby_compile] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - s

    src = compiled.source
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    key = src.hash
    cache = LiquidIL::RubyCompiler.class_variable_get(:@@iseq_cache)
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

stage_times.each { |stage, ns| puts "METRIC #{stage}_µs=#{(ns / 5000.0).round}" }
' 2>/dev/null) || true
if [ -n "$PIPELINE" ]; then
  echo "$PIPELINE"
fi
