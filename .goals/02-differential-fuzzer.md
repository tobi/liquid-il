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

### The hardest part #1: running both engines in one process, safely

Both engines run IN-PROCESS — throughput is the whole point of a fuzzer
(target: thousands of cases/sec, which a per-case subprocess round-trip
cannot deliver). `rake bench` and `rake bench:cold` already run reference
liquid and LiquidIL in one process with byte-validated outputs; the fuzzer
extends that precedent. But in-process coexistence is only safe inside a
specific envelope — enforce it, don't assume it:

- WHY it works: LiquidIL monkeypatches core classes (lib/liquid_il/
  core_ext.rb): `Object#to_liquid` RAISES for non-protocol objects, and an
  `IdentityToLiquid` mixin makes String/Symbol/Numeric/NilClass/TrueClass/
  FalseClass/Array/Hash/Range/Time/Date/DateTime return self. Reference
  liquid calls `value.to_liquid` when the value responds — for every type in
  the identity list that is exactly the value reference would have used
  anyway. Same for `to_liquid_value` (identity). So as long as environment
  values stay WITHIN the IdentityToLiquid-covered types, reference behavior
  is unchanged by our patches.
- ENFORCE the envelope: the generator's value pool must produce only
  identity-covered, JSON-able types (String/Integer/Float/nil/true/false/
  Array/Hash). Add an assertion in the runner that walks every generated env
  and rejects anything else — this is now a CORRECTNESS requirement, not
  just a serialization convenience. Never generate custom objects or drops
  in v1 (with our patches loaded, reference would raise on their `to_liquid`
  where clean reference would have passed them through — a false signal).
- Reference GLOBAL state must be reset per case: `Liquid::Template.
  file_system` is process-global in the reference gem — set it for each case
  that uses partials and restore the previous value in `ensure`. Check what
  else the liquid-spec reference adapter (examples/liquid_ruby.rb in the
  liquid-spec checkout) sets in setup and mirror it once at boot (e.g.
  disabling liquid-c).
- Rendering, mirroring the liquid-spec reference adapter:
  `Liquid::Template.parse(src, error_mode: mode.to_sym)` then
  `template.render(env)` — plain `render`, which embeds
  `Liquid error (...)` messages in output; that is what the spec suite pins.
  LiquidIL side: `LiquidIL::Template.parse(src).render(env)` (or with a
  `LiquidIL::Context` when the case has a filesystem). Catch exceptions from
  both and normalize to {ok:, output:|error_class:, message:}.
- Hangs: in-process means a pathological template blocks the run. Prevent
  rather than kill: cap generated range literals (|a-b| ≤ 1000), collection
  sizes, and nesting depth. Belt-and-braces: a watchdog thread that dumps
  the current seed+case if a single case exceeds 2s, so a hang is diagnosable
  and reproducible (then treat the hang itself as a finding).
- SUBPROCESS CONFIRMATION (only on mismatch, off the hot path): before
  recording a finding, re-run just that one case through a clean
  `bundle exec ruby -rliquid -rjson fuzz/ref_check.rb` subprocess that never
  loads liquid_il, and use ITS output as the reference ground truth. Cost is
  irrelevant (findings are rare); it guarantees no recorded finding is an
  artifact of in-process coexistence. If in-process reference output ever
  disagrees with clean-subprocess reference output, that is a separate,
  important finding about our core_ext — record it in its own bucket.

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
  round-trip JSON (the subprocess confirmation step ships them as JSON,
  and JSON-ability doubles as the IdentityToLiquid-envelope check).
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
  render, `render ... for/with`). Cases carry a
  `filesystem` hash; for the reference side install it per case:
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
  env handling is wrong — fix that first).
- Re-inject a known historical bug to prove the tool works end-to-end: check
  out commit 2ab67c7 in a worktree, point the LiquidIL side at that lib, and
  verify the fuzzer finds a `self[...]`-in-nested-loops divergence within a
  reasonable budget (it exists there; the fuzzer must find it).
- `rake test` and `rake bench:cold` stay green (the fuzzer must not touch
  production code paths at all — it is pure tooling; any LiquidIL bug FIXES
  that come out of findings follow the normal gates).
