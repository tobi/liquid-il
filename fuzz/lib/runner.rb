# frozen_string_literal: true

require_relative "gen"
require_relative "engines"
require_relative "oracle"
require_relative "shrink"
require_relative "finding"
require_relative "subprocess_confirm"
require_relative "envelope"

module Fuzz
  Report = Struct.new(:cases, :elapsed, :core_elapsed, :mismatches, :new_findings, :rule_counts,
                       :suppressed_counts, :hangs, :artifact_mismatches, :core_ext_disagreements,
                       :seed, keyword_init: true) do
    def cases_per_sec = elapsed.positive? ? (cases / elapsed).round(1) : 0.0

    # Throughput of JUST generate -> render both engines -> oracle compare,
    # excluding shrink/subprocess-confirm/YAML-write time. This is the
    # number goal 02's "thousands of cases/sec" target refers to -- shrink
    # + subprocess confirmation are explicitly off the hot path and only
    # run once per (rare, deduped) mismatch, so they dominate wall-clock on
    # a *first* run against an unfixed engine without being what the
    # generation throughput actually is.
    def core_cases_per_sec = core_elapsed.positive? ? (cases / core_elapsed).round(1) : 0.0

    def summary
      "cases=#{cases} (#{cases_per_sec}/s overall, #{core_cases_per_sec}/s core generate+render+compare) " \
        "mismatches=#{mismatches} unique_new=#{new_findings.size} " \
        "hangs=#{hangs} artifact_self_consistency_mismatches=#{artifact_mismatches} " \
        "core_ext_disagreements=#{core_ext_disagreements} suppressed=#{suppressed_counts} seed=#{seed}"
    end
  end

  # Batch loop: generate -> render both engines in-process -> oracle compare
  # -> (on divergence) shrink -> clean-subprocess confirm -> dedupe -> record.
  # See .goals/02-differential-fuzzer.md for the full design rationale.
  class Runner
    ARTIFACT_CHECK_EVERY = 20
    SUPPRESSION_WARN_THRESHOLD = 0.05

    def initialize(seed: nil, time_budget: 60, case_budget: 2000,
                   findings_dir: File.expand_path("../findings", __dir__),
                   verbose: true)
      @seed = seed || Random.new_seed
      @seed_random = Random.new(@seed)
      @time_budget = time_budget
      @case_budget = case_budget
      @findings_dir = findings_dir
      @core_ext_dir = File.join(@findings_dir, "core_ext")
      @hangs_dir = File.join(@findings_dir, "hangs")
      @verbose = verbose
    end

    def run
      start = Time.now
      core_elapsed = 0.0
      cases = 0
      mismatches = 0
      hangs = 0
      artifact_mismatches = 0
      core_ext_disagreements = 0
      rule_counts = Hash.new(0)
      suppressed_counts = Hash.new(0)
      new_findings = []

      loop do
        break if Time.now - start > @time_budget
        break if cases >= @case_budget

        core_t0 = Time.now
        kase = Gen.new(@seed_random.rand(2**31)).generate
        Envelope.assert!(kase.environment) # generator invariant -- see fuzz/lib/envelope.rb
        cases += 1

        ref = ReferenceEngine.render(kase)
        lil = LiquidILEngine.render(kase)
        verdict = Oracle.compare(ref, lil)
        core_elapsed += Time.now - core_t0

        case verdict.status
        when :match
          suppressed_counts[verdict.rule] += 1 if verdict.rule
        when :hang
          hangs += 1
          handle_hang(kase, verdict, ref, lil)
        when :finding
          mismatches += 1
          rule_counts[verdict.rule] += 1
          sig = handle_finding(kase, ref, lil, verdict)
          new_findings << sig if sig
        end

        if lil[:ok] && lil[:template] && (cases % ARTIFACT_CHECK_EVERY).zero?
          art = LiquidILEngine.render_via_artifact(lil[:template], kase)
          unless art[:hang] || (art[:ok] == lil[:ok] && art[:output] == lil[:output])
            artifact_mismatches += 1
            record_artifact_mismatch(kase, lil, art)
          end
        end
      end

      warn_hot_suppressions(suppressed_counts, cases)

      Report.new(
        cases: cases, elapsed: Time.now - start, core_elapsed: core_elapsed, mismatches: mismatches,
        new_findings: new_findings, rule_counts: rule_counts,
        suppressed_counts: suppressed_counts, hangs: hangs,
        artifact_mismatches: artifact_mismatches,
        core_ext_disagreements: core_ext_disagreements, seed: @seed,
      )
    end

    private

    def log(msg) = (puts msg if @verbose)

    def handle_finding(kase, ref, lil, verdict)
      rule = verdict.rule
      minimized = Shrink.minimize(kase) do |candidate|
        cref = ReferenceEngine.render(candidate)
        clil = LiquidILEngine.render(candidate)
        cv = Oracle.compare(cref, clil)
        cv.status == :finding && cv.rule == rule
      end

      final_ref = ReferenceEngine.render(minimized)
      final_lil = LiquidILEngine.render(minimized)
      signature = Finding.signature(minimized, final_ref, final_lil, rule)
      return nil if Finding.known?(@findings_dir, signature)

      confirmed, agrees = SubprocessConfirm.confirm(minimized, final_ref)
      if agrees == false
        record_core_ext_disagreement(minimized, final_ref, confirmed)
        return nil # ground truth is ambiguous -- not a LiquidIL finding (see fuzz/lib/subprocess_confirm.rb)
      end
      ground_truth = agrees.nil? ? final_ref : confirmed # subprocess unavailable/errored: fall back to in-process ref, noted below

      path = Finding.write!(@findings_dir, minimized, ground_truth, final_lil,
        rule: rule, signature: signature, subprocess_confirmed: agrees,
        note: verdict.detail && "rule=#{rule} detail=#{verdict.detail}#{" (subprocess unavailable, used in-process reference)" if agrees.nil?}")
      log "FINDING [#{rule}] seed=#{kase.seed} -> #{path}"
      signature
    end

    # Deliberately NOT shrunk: minimizing would mean re-rendering many
    # candidates, each potentially eating another full timeout -- belt-and-
    # braces says dump-and-move-on, not spend the run budget chasing a hang.
    # The recorded seed + full (unminimized) template/environment is enough
    # to reproduce and manually minimize later.
    def handle_hang(kase, verdict, ref, lil)
      side = verdict.rule == :reference_hang ? "reference" : "liquidil"
      signature = "hang::#{side}::#{kase.template_src.bytesize}"
      return if Finding.known?(@hangs_dir, signature)

      Finding.write!(@hangs_dir, kase, ref, lil,
        rule: verdict.rule, signature: signature,
        note: "#{side} engine exceeded the per-case render timeout -- see .goals/02-differential-fuzzer.md \"Hangs\".")
      log "HANG [#{side}] seed=#{kase.seed}"
    end

    def record_core_ext_disagreement(kase, inprocess_ref, subprocess_ref)
      signature = "core_ext::#{inprocess_ref[:output].to_s[0, 40]}|#{subprocess_ref[:output].to_s[0, 40]}"
      return if Finding.known?(@core_ext_dir, signature)

      Finding.write!(@core_ext_dir, kase, subprocess_ref, inprocess_ref,
        rule: :core_ext_coexistence_disagreement, signature: signature,
        note: "In-process reference render disagreed with a clean subprocess reference render for the SAME case " \
              "(no LiquidIL involved) -- this points at LiquidIL's core_ext.rb monkeypatches, not the engine. " \
              "`expected`/`_liquidil_actual` here are reused as subprocess/in-process reference output, respectively.")
      log "CORE_EXT DISAGREEMENT seed=#{kase.seed}"
    end

    def record_artifact_mismatch(kase, lil, art)
      dir = File.join(@findings_dir, "artifact_self_consistency")

      minimized = Shrink.minimize(kase) do |candidate|
        clil = LiquidILEngine.render(candidate)
        next false unless clil[:ok] && clil[:template]

        cart = LiquidILEngine.render_via_artifact(clil[:template], candidate)
        !cart[:hang] && (cart[:ok] != clil[:ok] || cart[:output] != clil[:output])
      end

      final_lil = LiquidILEngine.render(minimized)
      final_art = LiquidILEngine.render_via_artifact(final_lil[:template], minimized)
      signature = "artifact::#{Finding.structural_key(minimized.ast)}"
      return if Finding.known?(dir, signature)

      Finding.write!(dir, minimized, { ok: true, output: final_lil[:output] }, final_art,
        rule: :artifact_self_consistency, signature: signature,
        note: "LiquidIL direct render disagreed with its own to_artifact -> Artifact.load -> render roundtrip " \
              "for the identical (template, environment) -- a serializer/codegen bug, independent of reference liquid.")
      log "ARTIFACT SELF-CONSISTENCY MISMATCH seed=#{kase.seed}"
    end

    def warn_hot_suppressions(suppressed_counts, cases)
      return if cases.zero?

      suppressed_counts.each do |rule, count|
        next unless count.to_f / cases > SUPPRESSION_WARN_THRESHOLD

        warn "WARNING: suppression rule #{rule} fired on #{count}/#{cases} cases " \
             "(#{(100.0 * count / cases).round(1)}%) -- per goal 02 doc, the generator should stop " \
             "generating this construct instead of relying on suppression."
      end
    end
  end
end
