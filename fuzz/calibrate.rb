#!/usr/bin/env ruby
# frozen_string_literal: true

# Calibration (goal 02 doc, "Verification"): lift ~50 real templates+
# environments straight from liquid-spec's suites and run them UNMUTATED
# through the exact same generate-free path the fuzzer uses (in-process
# reference render + in-process LiquidIL render + Oracle.compare). Since
# the full liquid-spec suite is green (5333/0/0), this must report ZERO
# :finding verdicts -- if it flags a template the suite passes, the oracle
# or the env/filesystem plumbing is wrong, and that must be fixed before
# trusting anything the fuzzer itself reports.
#
# Usage: bundle exec ruby fuzz/calibrate.rb   (rake fuzz:calibrate)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "liquid_il"
require "liquid"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "yaml"
require "case"
require "envelope"
require "engines"
require "oracle"

TARGET_COUNT = 50

def liquid_spec_root
  Gem::Specification.find_by_name("liquid-spec").gem_dir
rescue Gem::MissingSpecError
  begin
    require "bundler"
    Bundler.load.specs.find { |s| s.name == "liquid-spec" }.full_gem_path
  end
end

def candidate_files(root)
  # Suites of plain (non-Shopify, non-generated-error) behavioral specs --
  # the ones the reference adapter is expected to match byte-for-byte.
  %w[basics liquid_ruby].each_with_object([]) do |dir, files|
    files.concat(Dir.glob(File.join(root, "specs", dir, "**", "*.yml")))
  end
end

def load_specs(files)
  files.flat_map do |f|
    data = YAML.unsafe_load_file(f)
    # Two shapes in the wild: a bare top-level Array of spec Hashes, or a
    # Hash with a "specs" key (and possibly `_metadata`/suite-config-only
    # files with no "specs" key at all, e.g. suite.yml -- skipped).
    list = data.is_a?(Array) ? data : (data.is_a?(Hash) ? data["specs"] : nil)
    Array(list).select { |s| s.is_a?(Hash) && s["template"] }
  end
end

root = liquid_spec_root
abort "liquid-spec gem not found -- run `bundle install`" unless root

specs = load_specs(candidate_files(root))
puts "Scanned #{specs.size} candidate specs from #{root}/specs/{basics,liquid_ruby}"

selected = []
specs.each do |s|
  break if selected.size >= TARGET_COUNT

  env = s["environment"] || {}
  next unless Fuzz::Envelope.safe?(env) # skip specs using Drops/Time/etc -- outside the fuzzer's envelope, not a calibration signal

  fs = s["filesystem"] || {}
  next unless fs.is_a?(Hash) && fs.values.all? { |v| v.is_a?(String) }

  error_mode = (s["error_mode"] || "strict").to_s.delete_prefix(":").to_sym
  selected << Fuzz::Case.literal(
    seed: s["name"], template_src: s["template"], environment: env,
    filesystem: fs, error_mode: error_mode,
  )
end

abort "Only found #{selected.size} usable specs (need #{TARGET_COUNT}) -- widen candidate_files" if selected.size < TARGET_COUNT

puts "Calibrating on #{selected.size} unmutated liquid-spec templates (must be ZERO :finding verdicts)..."

findings = []
suppressed = Hash.new(0)
selected.each do |kase|
  ref = Fuzz::ReferenceEngine.render(kase)
  lil = Fuzz::LiquidILEngine.render(kase)
  verdict = Fuzz::Oracle.compare(ref, lil)
  case verdict.status
  when :match
    suppressed[verdict.rule] += 1 if verdict.rule
  when :finding, :hang
    findings << [kase, ref, lil, verdict]
  end
end

puts "suppressed=#{suppressed}"

if findings.empty?
  puts "PASS: 0 mismatches across #{selected.size} unmutated liquid-spec templates."
  exit 0
end

puts
puts "FAIL: #{findings.size} unmutated liquid-spec templates mismatched -- the oracle or env/filesystem plumbing is wrong."
findings.each do |kase, ref, lil, verdict|
  puts "-- #{kase.seed} [#{verdict.status}/#{verdict.rule}] --"
  puts "   template: #{kase.template_src[0, 160].inspect}"
  puts "   ref: #{ref.reject { |k, _| k == :template }.inspect[0, 200]}"
  puts "   lil: #{lil.reject { |k, _| k == :template }.inspect[0, 200]}"
end
exit 1
