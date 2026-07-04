# frozen_string_literal: true

# Artifact byte-attribution tool (docs/win_all_scenarios.md, workstream A.1).
#
# For each bench spec, breaks down where the compiled artifact's bytes come
# from: raw text payload vs generated-code structure, and which codegen
# patterns dominate the generated source. Every emitted-bytes optimization
# should be justified by this report before and after.
#
#   template_bytes    Liquid source (main template + partials)
#   payload_bytes     WRITE_RAW string payload in the optimized IL (unavoidable)
#   ruby_bytes/lines  generated Ruby source
#   iseq_bytes        RubyVM::InstructionSequence binary of that source
#   artifact_bytes    persisted artifact string (envelope included)
#   insns             ISeq instruction count (disasm lines as proxy)
#   B/insn            iseq_bytes / insns — the per-operation overhead
#
# Pattern table: source bytes consumed by each codegen pattern (regex match
# lengths — an attribution guide, not an exact decomposition).
#
# Usage:
#   bundle exec ruby bench/bytes_bench.rb [spec_name ...]
#   rake bench:bytes

require "yaml"
require "json"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "liquid_il"

class BenchFS
  def initialize(templates) = @templates = templates
  def read_template_file(name, _context = nil) = @templates[name.to_s]
end

PATTERNS = {
  "raw appends (_O <<)" => /^\s*_O << (?:"(?:[^"\\]|\\.)*"(?: << "(?:[^"\\]|\\.)*")*)( unless _S\.has_interrupt\?)?\n/,
  "output helper (oa/wv)" => /_H\.(?:oa|wv|wvp)\([^\n]*\)/,
  "lookups (lookup/lf/l/bl)" => /(?:_S\.lookup|__partial_scope__\.lookup|_H\.(?:lf|l|bl|lookup))\((?:[^()]|\([^()]*\))*\)/,
  "filters (ff/cf/cff/ccf)" => /_[FH]\.c?c?ff?\(/,
  "comparisons (cmp/ce?/ct)" => /_(?:H\.cmp|U\.ce\?|H\.ct)\(/,
  "truthy wrappers" => /\(\(_t = [^\n]*?to_liquid_value; _t\)\)/,
  "partial plumbing" => /__partial_\w+__|_H\.ip\(|caller_line|parent_cycle_state|__parent_scope__|isolated/,
  "loop plumbing" => /__(?:coll|len|idx|for|item)\d*\w*__|_H\.(?:ti|wrap_for_loop)\(|_S\.(?:push|pop)_(?:scope|forloop)|forloop/,
  "temps" => /__temp_\d+__/,
  "interrupt guards" => /has_interrupt\?|throw\(:loop_break|_S\.push_interrupt/,
  "comments" => /^\s*#[^\n]*\n/,
  "indentation" => /^[ \t]+/,
}.freeze

def load_specs(only_names)
  yml = YAML.safe_load(File.read(File.expand_path("../specs/partials/partials.yml", __dir__)), aliases: true)
  specs = yml["specs"].select { |s| s["name"]&.start_with?("bench_") }
  specs = specs.select { |s| only_names.include?(s["name"]) } unless only_names.empty?
  specs
end

def fmt_kb(bytes) = bytes >= 1024 ? "%.1fKB" % (bytes / 1024.0) : "#{bytes}B"

rows = []
load_specs(ARGV).each do |spec|
  fs_data = spec["filesystem"] || {}
  ctx = LiquidIL::Context.new(file_system: BenchFS.new(fs_data))
  template = ctx.parse(spec["template"])

  src = template.instance_variable_get(:@compiled_source)
  iseq = RubyVM::InstructionSequence.compile(LiquidIL::RubyCompiler.compact_source(src))
  iseq_bytes = iseq.to_binary.bytesize
  insns = iseq.disasm.lines.count { |l| l.match?(/^\d{4} /) }
  payload = template.instructions.sum { |i| i[0] == :WRITE_RAW ? i[1].bytesize : 0 }

  pattern_bytes = PATTERNS.transform_values { |re| src.scan(re).sum { |m| Array(m).first.to_s.bytesize.nonzero? || Regexp.last_match(0).bytesize } }
  # scan with groups returns group captures; use a simpler pass for accuracy:
  pattern_bytes = {}
  pattern_counts = {}
  PATTERNS.each do |label, re|
    bytes = 0
    count = 0
    src.scan(re) { bytes += Regexp.last_match(0).bytesize; count += 1 }
    pattern_bytes[label] = bytes
    pattern_counts[label] = count
  end

  rows << {
    name: spec["name"],
    template_bytes: spec["template"].bytesize + fs_data.values.sum(&:bytesize),
    payload: payload,
    ruby_bytes: src.bytesize,
    ruby_lines: src.count("\n"),
    iseq_bytes: iseq_bytes,
    artifact_bytes: template.to_artifact.bytesize,
    insns: insns,
    patterns: pattern_bytes,
    counts: pattern_counts,
  }
end

puts "| spec | liquid | payload | ruby (lines) | iseq | artifact | insns | B/insn |"
puts "|---|---:|---:|---:|---:|---:|---:|---:|"
rows.each do |r|
  puts "| #{r[:name].sub(/\Abench_/, "")} | #{fmt_kb(r[:template_bytes])} | #{fmt_kb(r[:payload])} | " \
       "#{fmt_kb(r[:ruby_bytes])} (#{r[:ruby_lines]}) | #{fmt_kb(r[:iseq_bytes])} | #{fmt_kb(r[:artifact_bytes])} | " \
       "#{r[:insns]} | #{(r[:iseq_bytes].to_f / r[:insns]).round(1)} |"
end

puts
puts "Generated-source bytes by pattern (count ×, across all specs):"
totals = Hash.new(0)
counts = Hash.new(0)
rows.each do |r|
  r[:patterns].each { |k, v| totals[k] += v }
  r[:counts].each { |k, v| counts[k] += v }
end
total_ruby = rows.sum { |r| r[:ruby_bytes] }
totals.sort_by { |_, v| -v }.each do |label, bytes|
  puts "  %-28s %8s  (%4d×, %4.1f%%)" % [label, fmt_kb(bytes), counts[label], 100.0 * bytes / total_ruby]
end
attributed = totals.values.sum
puts "  %-28s %8s  (%.1f%% attributed; overlaps possible)" % ["TOTAL generated", fmt_kb(total_ruby), 100.0 * attributed / total_ruby]
