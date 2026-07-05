# Differential fuzzer: LiquidIL vs reference `liquid`

Pure tooling. See [`.goals/02-differential-fuzzer.md`](../.goals/02-differential-fuzzer.md)
for the full design rationale -- this file is a usage/layout reference.

## Commands

```bash
rake fuzz              # 60s or 2000 cases; exits nonzero on a NEW finding
rake fuzz:long         # 10 minutes or 100,000 cases (override TIME=/CASES=)
rake fuzz:calibrate    # must report ZERO mismatches on 50 real liquid-spec templates
rake fuzz:rediscover   # verify the tool rediscovers the historical self[...] bug at 2ab67c7

SEED=1234 bundle exec ruby fuzz/run.rb        # reproduce a specific run
TIME=30 CASES=500 bundle exec ruby fuzz/run.rb
```

## Layout

- `lib/gen.rb` -- seeded, weighted, grammar-based template + environment +
  filesystem generator. Every template is built from constructs both
  engines are expected to parse (no free-form bytes).
- `lib/render.rb` -- turns generator AST nodes into Liquid source text.
  Must tolerate degenerate/shrunk structure (empty bodies, missing fields).
- `lib/case.rb` -- a generated (or literal) `(template, environment,
  filesystem, error_mode)` case, keeping the AST around for shrinking.
- `lib/envelope.rb` -- enforces the in-process coexistence envelope: every
  environment value must be an identity-covered, JSON-able type (String/
  Integer/Float/nil/true/false/Array/Hash-with-String-keys). This is a
  correctness requirement, not a serialization nicety -- see the file.
- `lib/engines.rb` -- in-process render wrappers for both engines, plus the
  artifact self-consistency check (render -> to_artifact -> load -> render).
- `lib/oracle.rb` -- the comparison pipeline: parse errors compared as a
  boolean, hangs bucketed separately, everything else compared byte-for-
  byte with NO normalization (numeric formatting and hash order are real
  bugs historically -- never suppressed).
- `lib/shrink.rb` -- generic structural ddmin over the whole (ast,
  environment, filesystem) tree.
- `lib/finding.rb` -- dedup signature + liquid-spec-format YAML writer.
- `lib/subprocess_confirm.rb` + `ref_check.rb` -- off-the-hot-path clean-
  subprocess confirmation before a finding is recorded (never loads
  liquid_il, so it can't be affected by LiquidIL's core_ext.rb patches).
- `lib/runner.rb` + `run.rb` -- the batch loop and CLI entrypoint.
- `calibrate.rb` -- runs 50 unmutated liquid-spec templates through the
  same in-process pipeline; must be zero mismatches (see rake task above).
- `rediscover.rb` / `rediscover_inner.rb` -- checks out commit 2ab67c7 into
  a worktree and points a subprocess's $LOAD_PATH at its lib/ instead of
  this repo's, to verify the tool still finds the historical
  self[...]-in-nested-loops bug.
- `findings/` -- one YAML file per minimized, subprocess-confirmed
  divergence (liquid-spec format: name/template/environment/expected/
  complexity/hint), `expected` taken from the reference gem. Sub-buckets:
  `findings/hangs/` (either engine exceeded the per-case timeout),
  `findings/core_ext/` (in-process reference disagreed with a clean
  subprocess reference for the SAME case -- points at LiquidIL's core_ext
  monkeypatches, not the engine), `findings/artifact_self_consistency/`
  (LiquidIL disagreed with its own artifact roundtrip).

## Status

The first real `rake fuzz` runs against current `main` found and recorded
real divergences (see `findings/`) -- expected per the goal doc ("If the
fuzzer finds real divergences in current LiquidIL... findings are the
deliverable"); fixing them is separate follow-up work, not part of this
tool. Two systemic, high-value classes worth reading first:

- `line_number_prefix_format` -- LiquidIL always prefixes embedded runtime-
  error text with `(line N)`; reference omits it for some error paths
  (filter arity errors, numeric coercion errors).
- Several `cycle`/filter-argument findings where LiquidIL raises a runtime
  error (or renders nothing) for inputs reference coerces leniently.
