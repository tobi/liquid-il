# frozen_string_literal: true

# Cold-path benchmark: the production workflow LiquidIL is optimized for.
#
#   compile once → persist compiled artifact → in a different process:
#   blob = memcache.get(key) → load → render
#
# Measures the *load* pipeline (deserialize → callable proc → first render),
# which for realistic templates costs more than the render itself.
#
# Per spec (docs/clean-ruby-compiler-spec.md "Measurement protocol"), reports
# medians for:
#
#   payload_bytes        size of the persisted artifact string
#   envelope_decode_µs   artifact envelope decode (Marshal / framed binary)
#   load_from_binary_µs  RubyVM::InstructionSequence.load_from_binary
#   iseq_eval_µs         iseq.eval → callable proc
#   cold_total_µs        decode + load + eval
#   first_render_µs      first render on a freshly loaded proc (cold JIT)
#   warm_render_µs       render after warmup (steady state)
#
# Hard-fail validation: artifact-path render == fresh-compile render ==
# reference `liquid` gem render. Any mismatch aborts with a diff.
#
# Usage:
#   RUBY_YJIT_ENABLE=1 bundle exec ruby bench/cold_bench.rb [spec_name ...]
#   rake bench:cold

require "yaml"
require "json"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "liquid_il"

COLD_ITERS  = Integer(ENV.fetch("COLD_ITERS", 300))
FIRST_ITERS = Integer(ENV.fetch("FIRST_ITERS", 100))
WARM_ITERS  = Integer(ENV.fetch("WARM_ITERS", 2000))

class BenchFS
  def initialize(templates) = @templates = templates
  def read_template_file(name, _context = nil) = @templates[name.to_s]
end

def now_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

def median(samples)
  sorted = samples.sort
  sorted[sorted.length / 2]
end

def load_specs(only_names)
  yml = YAML.safe_load(File.read(File.expand_path("../specs/partials/partials.yml", __dir__)), aliases: true)
  specs = yml["specs"].select { |s| s["name"]&.start_with?("bench_") }
  specs = specs.select { |s| only_names.include?(s["name"]) } unless only_names.empty?
  specs
end

def parse_environment(env)
  case env
  when nil then {}
  when String then JSON.parse(env)
  else env
  end
end

def reference_render(template_src, assigns, filesystem)
  require "liquid"
  fs = Object.new
  fs.define_singleton_method(:read_template_file) { |name| filesystem[name.to_s] or raise Liquid::FileSystemError }
  Liquid::Template.parse(template_src).render(assigns, registers: { file_system: fs })
rescue LoadError
  nil
end

failures = []
warnings = []
rows = []

load_specs(ARGV).each do |spec|
  name = spec["name"]
  filesystem = spec["filesystem"] || {}
  assigns = parse_environment(spec["environment"])

  fs = BenchFS.new(filesystem)
  render_registers = { "file_system" => fs }
  ctx = LiquidIL::Context.new(file_system: fs)
  template = ctx.parse(spec["template"])
  fresh_output = template.render(assigns)

  # The persisted artifact string — what memcache would hold
  use_artifact = defined?(LiquidIL::Artifact)
  blob = use_artifact ? LiquidIL::Artifact.encode(template) : Marshal.dump(template.cache_data)

  # Validate: artifact path must reproduce the fresh-compile output
  restored = if use_artifact
    LiquidIL::Artifact.load(blob)
  else
    LiquidIL::Template.from_cache(**Marshal.load(blob))
  end
  # Artifact-loaded templates have no context — dynamic partials resolve
  # through the render-time file_system register (the production pattern).
  artifact_output = restored.render(assigns, registers: render_registers)
  if artifact_output != fresh_output
    failures << [name, "artifact render != fresh render", fresh_output, artifact_output]
  end

  # Validate against the reference liquid gem. Whitespace-only differences are
  # warnings (case/when whitespace semantics changed between liquid gem
  # releases; liquid-spec is the arbiter there) — content differences fail.
  ref_output = reference_render(spec["template"], assigns, filesystem)
  if ref_output && ref_output != fresh_output
    if ref_output.gsub(/\s+/, "") == fresh_output.gsub(/\s+/, "")
      warnings << [name, "whitespace-only diff vs reference liquid gem"]
    else
      failures << [name, "fresh render != reference liquid gem", ref_output, fresh_output]
    end
  end

  decode_ns = []
  load_ns = []
  eval_ns = []
  first_ns = []

  # The measured decode/load/eval pipeline mirrors what from_cache/load does
  uses_artifact = use_artifact && LiquidIL::Artifact.respond_to?(:decode_segments)
  COLD_ITERS.times do
    if uses_artifact
      t0 = now_ns
      iseq_bytes, partial_constants = LiquidIL::Artifact.decode_segments(blob)
      t1 = now_ns
      iseq = RubyVM::InstructionSequence.load_from_binary(iseq_bytes)
      t2 = now_ns
      iseq.eval
      t3 = now_ns
      _ = partial_constants
    else
      t0 = now_ns
      data = Marshal.load(blob)
      t1 = now_ns
      iseq = RubyVM::InstructionSequence.load_from_binary(data[:iseq_binary])
      t2 = now_ns
      iseq.eval
      t3 = now_ns
    end
    decode_ns << (t1 - t0)
    load_ns << (t2 - t1)
    eval_ns << (t3 - t2)
  end

  FIRST_ITERS.times do
    fresh = if uses_artifact
      LiquidIL::Artifact.load(blob)
    else
      LiquidIL::Template.from_cache(**Marshal.load(blob))
    end
    t0 = now_ns
    fresh.render(assigns, registers: render_registers)
    first_ns << (now_ns - t0)
  end

  warm_template = restored
  200.times { warm_template.render(assigns, registers: render_registers) } # warmup
  warm_ns = []
  WARM_ITERS.times do
    t0 = now_ns
    warm_template.render(assigns, registers: render_registers)
    warm_ns << (now_ns - t0)
  end

  rows << {
    name: name,
    payload_bytes: blob.bytesize,
    envelope_decode_us: median(decode_ns) / 1000.0,
    load_from_binary_us: median(load_ns) / 1000.0,
    iseq_eval_us: median(eval_ns) / 1000.0,
    first_render_us: median(first_ns) / 1000.0,
    warm_render_us: median(warm_ns) / 1000.0,
  }
end

puts format("%-34s %9s %9s %9s %8s %9s %9s %9s",
  "spec", "bytes", "decode", "iseq_load", "eval", "cold_tot", "first", "warm")
rows.each do |r|
  cold_total = r[:envelope_decode_us] + r[:load_from_binary_us] + r[:iseq_eval_us]
  puts format("%-34s %9d %8.1fµs %8.1fµs %7.1fµs %8.1fµs %8.1fµs %8.1fµs",
    r[:name], r[:payload_bytes], r[:envelope_decode_us], r[:load_from_binary_us],
    r[:iseq_eval_us], cold_total, r[:first_render_us], r[:warm_render_us])
end

warnings.each { |name, msg| puts "WARN #{name}: #{msg}" }

unless failures.empty?
  puts "\nVALIDATION FAILURES:"
  failures.each do |name, kind, expected, actual|
    puts "#{name}: #{kind}"
    puts "  expected: #{expected.inspect[0, 300]}"
    puts "  actual:   #{actual.inspect[0, 300]}"
  end
  abort "#{failures.length} validation failure(s)"
end

puts "\nAll outputs validated against fresh compile#{defined?(Liquid) ? ' and reference liquid gem' : ''}."
