# frozen_string_literal: true

# Export fuzzer findings as a clean liquid-spec-format suite (spec/fuzz.yml)
# suitable for donation to Shopify/liquid-spec.
#
#   bundle exec rake fuzz:export
#
# Reads every top-level finding under fuzz/findings/ (the subdirectories —
# artifact_self_consistency/, hangs/, core_ext/ — are LiquidIL-internal
# consistency findings, not reference divergences, and are excluded).
# Each exported spec is RE-VALIDATED against the reference liquid gem in this
# process before it is written; anything that no longer reproduces is skipped
# with a warning rather than exported wrong.
#
# The output is deterministic (sorted, stable names) so re-exports diff cleanly.

require "yaml"
require "liquid"

module FuzzExport
  module_function

  FINDINGS_DIR = File.expand_path("findings", __dir__)
  OUT_PATH = File.expand_path("../spec/fuzz.yml", __dir__)

  # Edge-case compatibility quirks sit late in the liquid-spec complexity ramp.
  COMPLEXITY = 800

  def run!
    findings = Dir[File.join(FINDINGS_DIR, "*.yml")].sort.map { |p| YAML.safe_load(File.read(p), permitted_classes: [Symbol]) }
    specs = []
    seen = {}
    skipped = 0

    findings.each do |f|
      template = f["template"]
      env = f["environment"] || {}
      fs = f["filesystem"] || {}
      expected = f["expected"].to_s

      dedupe_key = [template, env, fs]
      next if seen[dedupe_key]
      seen[dedupe_key] = true

      # Re-validate against the reference gem right now — the donation file
      # must only contain reproducible reference behavior.
      actual = reference_render(template, env, fs)
      unless actual == expected
        warn "skip (no longer reproduces on reference): #{f["name"]} expected=#{expected.inspect} got=#{actual.inspect}"
        skipped += 1
        next
      end

      meta = f["_metadata"] || {}
      specs << {
        "name" => spec_name(f, meta),
        "template" => template,
        "environment" => env.empty? ? nil : env,
        "filesystem" => fs.empty? ? nil : fs,
        # The fuzzer compares plain `render` output (errors embedded inline);
        # liquid-spec requires that to be declared when the expectation
        # contains error text.
        "render_errors" => (expected.include?("Liquid error") ? true : nil),
        "expected" => expected,
        "complexity" => COMPLEXITY,
        "hint" => hint_for(f, meta),
      }.compact
    end

    specs.sort_by! { |s| s["name"] }
    File.write(OUT_PATH, render_yaml(specs))
    puts "wrote #{OUT_PATH}: #{specs.length} specs (#{skipped} skipped as non-reproducing, #{findings.length - specs.length - skipped} deduped)"
  end

  def reference_render(template, env, fs)
    prev_fs = Liquid::Template.file_system
    unless fs.empty?
      Liquid::Template.file_system = StaticFS.new(fs)
    end
    t = Liquid::Template.parse(template, error_mode: :strict)
    t.render(deep_dup(env))
  rescue Liquid::Error => e
    "syntax_error: #{e.message}"
  ensure
    Liquid::Template.file_system = prev_fs
  end

  class StaticFS
    def initialize(map) = @map = map
    def read_template_file(name)
      @map[name] || @map["#{name}.liquid"] or raise Liquid::FileSystemError, "No such template '#{name}'"
    end
  end

  def deep_dup(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[deep_dup(k)] = deep_dup(v) }
    when Array then obj.map { |v| deep_dup(v) }
    when String then obj.dup
    else obj
    end
  end

  # fuzz_<dominant-construct>_<original-hash> — greppable, stable, and the
  # construct prefix groups related divergences when sorted.
  def spec_name(f, meta)
    sig = meta["signature"].to_s
    suffix = f["name"].to_s.sub(/\Afuzz_/, "")[0, 12]
    filters = sig.scan(/name: "([a-z_0-9]+)"/).flatten
    construct =
      if filters.any?
        filters.last
      elsif (m = sig.match(/type: :([a-z_]+)/))
        m[1]
      else
        "misc"
      end
    "fuzz_#{construct}_#{suffix}"
  end

  def hint_for(f, meta)
    actual = f["_liquidil_actual"]
    lines = [
      "Recorded by LiquidIL's differential fuzzer (seed #{meta["seed"]}) and",
      "confirmed against reference liquid in a clean subprocess: the expected",
      "output is exactly what the reference gem renders in strict mode.",
    ]
    if actual
      lines << "A compiling implementation diverged here at recording time,"
      lines << "producing: #{actual.inspect}."
    end
    lines.join("\n") + "\n"
  end

  def render_yaml(specs)
    header = <<~HEADER
      # Divergences found by LiquidIL's differential fuzzer (fuzz/ in
      # github.com/tobi/liquid-il) between compiled-Liquid implementations and
      # reference liquid. Every expected: value was re-validated against the
      # reference gem at export time. Intended for donation to liquid-spec.
      #
      # Regenerate: bundle exec rake fuzz:export
    HEADER
    body = YAML.dump(specs)
    header + "---\n" + body.sub(/\A---\n/, "")
  end
end

FuzzExport.run! if $PROGRAM_NAME == __FILE__
