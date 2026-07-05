# Goal 2: Differential fuzzer against reference liquid

## Objective

Build a template fuzzer that renders randomly generated (template,
environment) pairs through BOTH the reference `liquid` gem (5.13) and
LiquidIL, diffs the outputs, shrinks any mismatch to a minimal reproduction,
and emits it as a liquid-spec YAML candidate.

Why: 5,333 green specs still cannot cover the interaction space. The
`self[...]`-inside-three-nested-loops bug (see liquid-spec
`self_sees_loop_variables_across_three_nested_loops`) shipped under a fully
green suite — it was only found by reasoning about the codegen. A fuzzer finds
this class of bug mechanically. Every confirmed mismatch becomes either a
LiquidIL fix or a new upstream spec (the user's standing directive: when
liquid-spec is wrong, flag it; when we're wrong, fix us).

## Deliverables

1. `fuzz/` directory in this repo: generator, runner, shrinker, corpus.
2. `rake fuzz` (time-boxed, e.g. 60s smoke run) and `rake fuzz:long`.
3. `fuzz/findings/` — one YAML file per minimized, confirmed divergence, in
   liquid-spec format (name/template/environment/expected/complexity/hint)
   with `expected` taken FROM THE REFERENCE GEM's output.
4. Zero known divergences at the end: each finding is either fixed in
   LiquidIL (with the finding promoted into liquid-spec upstream at
   ~/src/tries/2026-07-04-Shopify-liquid-spec) or documented as an accepted,
   feature-gated difference (see "Known legitimate differences").

## Architecture — read this before writing code

### The hardest part #1: process isolation of the two engines

LiquidIL monkeypatches core classes (lib/liquid_il/core_ext.rb):
`Object#to_liquid` RAISES `LiquidIL::NoMethodError` for non-protocol objects,
and an `IdentityToLiquid` mixin makes String/Numeric/Hash/Array/etc. return
self. The reference gem, loaded into the same process, then sees a
`to_liquid` method on EVERY object. For plain JSON-able data this happens to
be benign (identity), which is why `rake bench` runs both in one process —
but a fuzzer explores adversarial values where the divergence-of-environment
becomes a false signal (you would be fuzzing the interaction of our
monkeypatch with reference liquid, not reference liquid itself).

Therefore: run the REFERENCE engine in a clean subprocess that never loads
liquid_il. Protocol (keep it this simple):

- Parent (fuzzer) spawns one worker: `bundle exec ruby fuzz/ref_worker.rb`.
  The worker requires ONLY `liquid` and `json`, then loops over stdin lines:
  `{"template": "...", "env": {...}, "error_mode": "strict"}` → renders →
  writes one stdout line: `{"ok": true, "output": "..."}` or
  `{"ok": false, "error_class": "...", "message": "..."}`.
- Rendering in the worker, mirroring how liquid-spec's reference adapter does
  it (see examples/liquid_ruby.rb in the liquid-spec checkout):
  `Liquid::Template.parse(src, error_mode: mode.to_sym)` then
  `template.render(env)` — note plain `render`, which embeds
  `Liquid error (...)` messages in output, PLUS a second pass with `render!`
  captured separately if you want strict-error comparison. Start with plain
  `render` only; it is what the spec suite mostly pins.
- Timeouts: wrap each worker request with a deadline (2s); on timeout, kill
  and respawn the worker, record the template as a hang-finding (hangs are
  findings too — e.g. pathological parse complexity).
- LiquidIL side runs in-process:
  `LiquidIL::Template.parse(src).render(env)` with exceptions caught and
  normalized to the same JSON shape.

### The hardest part #2: the comparison oracle (noise control)

A naive `==` on outputs drowns you in known, legitimate differences within an
hour. Build the oracle as a pipeline of normalizers + a gate list, and make
every suppression EXPLICIT and COUNTED (print suppression counts per run —
if one suppression rule fires on >5% of cases, the generator should stop
generating that construct instead).

Known legitimate difference classes (seed the list with these; extend only
with evidence):
1. Error message formats. Reference: `Liquid error (line N): msg` /
   `Liquid syntax error (line N): msg`. LiquidIL matches these in most cases
   (the spec suite pins thousands), but for PARSE errors compare only
   "did both raise a syntax error?" (boolean), not message text.
2. Features LiquidIL intentionally lacks or adds: the reference adapter in
   liquid-spec declares missing features
   `self_environment_shadowing, drop_class_output, shopify_filters,
   shopify_includes, shopify_blank, shopify_error_handling,
   shopify_error_format, shopify_string_access, lax_parsing` — do not
   generate constructs that depend on Shopify-platform filters/tags at all
   (the generator's filter list should be the standard set only).
3. Float formatting followed to reference by the suite; if a mismatch is
   purely `1.0` vs `1`, keep it — those ARE real bugs historically, do not
   suppress numeric formatting.
4. Hash iteration order: both engines preserve Ruby hash insertion order —
   no suppression needed.

Anything not on the list is a FINDING. The finding's ground truth is the
reference gem's output — but sanity-check against the suite's philosophy:
if reference output looks insane (see QUIRKS.md in the liquid-spec repo),
record it as a candidate quirk-spec rather than silently conforming.

### Generator design

Grammar-based, seeded, and weighted. NO free-form random bytes — every
generated template must be built from constructs both engines parse.

- A `Gen` class with a seeded `Random` (print the seed on every run; a
  finding must be reproducible from `SEED=`).
- Value pool for environments: strings (ASCII, multibyte UTF-8, strings
  containing Liquid syntax like `{{`, strings containing `_S` and
  `PRICE_START` — this class of payload found real bugs), integers (0, 1,
  -1, 2**62, huge negative), floats (0.0, -0.5, NaN excluded — JSON),
  nil, booleans, nested arrays/hashes 1–3 deep, empty array/hash, hashes
  with integer keys and with symbol-looking string keys. Values must
  round-trip JSON (the ref worker gets them via JSON).
- Template AST nodes with weights (start with these, tune by coverage):
  raw text (incl. multibyte + `{`-adjacent text), `{{ var }}`,
  `{{ a.b.c }}`, `{{ a[expr] }}`, `{{ self[expr] }}`, filters chained 1–3
  deep from the standard set with literal and variable args, `assign`,
  `capture`, `if/elsif/else` with comparisons and and/or, `unless`, `case/when`,
  `for` (with else, limit:, offset:, offset: continue, reversed, over
  ranges `(a..b)`), nested loops 2–4 deep reusing and shadowing variable
  names, `forloop.index/first/last/length/parentloop` chains, `break`/
  `continue` (inside ifs inside loops), `cycle` (named and unnamed, variable
  values), `increment`/`decrement`, `tablerow` with cols/limit/offset,
  whitespace-trim variants `{%- -%}`/`{{- -}}`, `raw`, `comment`, `echo`,
  `liquid` tag blocks, `render`/`include` (see next bullet).
- Partials: generate a small filesystem (1–4 partials, possibly recursive to
  depth 2, possibly reading/assigning caller vars in include, args in
  render, `render ... for/with`). The ref worker must accept a
  `"filesystem": {...}` key and install a file system:
  in reference liquid that is
  `Liquid::Template.file_system = Liquid::StaticFileSystem.new(hash)` if
  available, else a tiny custom object with `read_template_file(name)`. Look
  at how liquid-spec's reference adapter installs spec filesystems
  (grep `filesystem` under the liquid-spec checkout's lib/) and copy that
  exactly — include/render semantics differ with partial-name extension
  handling and this must match the harness, not your guess.
- Size budget: templates 50–2000 chars; deep nesting is more valuable than
  length.

### Shrinker

On mismatch, minimize BEFORE recording:
1. Structural shrink at the generator-AST level (drop child nodes one at a
   time, re-render both engines, keep the divergence) — far more effective
   than textual shrinking; you have the AST, use it.
2. Then environment shrink: remove env keys / shrink arrays while the
   divergence persists.
3. Emit the minimized case: template + env + both outputs + seed into
   `fuzz/findings/<hash>.yml`, liquid-spec format, `expected` = reference
   output, plus a comment block with LiquidIL's (wrong) output and the seed.
4. Dedupe findings by a signature: (first divergent construct kind, LiquidIL
   error class or first-divergence character context). Without dedupe one bug
   produces thousands of findings.

### Runner mechanics

- Batch loop: generate N cases, render both, compare, shrink, dedupe, report:
  `cases=..., mismatches=..., unique=..., suppressed={rule: count}, seed=...`.
- `rake fuzz` = 60 seconds or 2,000 cases, whichever first; exits nonzero if
  a NEW unique finding appeared (so it can gate CI later).
- Also run every generated case through LiquidIL's ARTIFACT path once per N
  cases (to_artifact → load → render) and compare against LiquidIL's direct
  render — that is a self-consistency oracle for the serializer, free extra
  coverage (`rake bench:cold` does this for 12 fixed templates; the fuzzer
  does it for thousands).

## Verification

- Seed the corpus by mutating 50 templates lifted from liquid-spec suites and
  confirm the fuzzer reports ZERO mismatches on unmutated spec templates
  (calibration: if it flags a template the suite passes, the oracle or the
  worker env-handling is wrong — fix that first).
- Re-inject a known historical bug to prove the tool works end-to-end: check
  out commit 2ab67c7 in a worktree, point the LiquidIL side at that lib, and
  verify the fuzzer finds a `self[...]`-in-nested-loops divergence within a
  reasonable budget (it exists there; the fuzzer must find it).
- `rake test` and `rake bench:cold` stay green (the fuzzer must not touch
  production code paths at all — it is pure tooling; any LiquidIL bug FIXES
  that come out of findings follow the normal gates).
