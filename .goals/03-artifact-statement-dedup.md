# Goal 3: IL statement-run dedup — flip the last red remote-hit row

## Objective

storefront_order_email is the last individual scenario row LiquidIL loses to
liquid-vm: remote-hit 76µs vs 70µs, artifact 13.8KB vs 5.0KB (we win its
in-process 40µs vs 47µs and cache-miss is a separate goal). Remote-hit cost ≈
ISeq load (~3µs/KB) + one render, so the lever is the artifact: −2KB ≈ −6µs ≈
parity or better.

Email has NO partials to melt — all prior artifact tranches (runtime drivers,
lambda restructuring) don't apply. Its remaining fat is TEMPLATE-AUTHORED
repetition: the "money" pattern

```liquid
{% assign d = x | divided_by: 100 %}{% assign c = x | modulo: 100 %}
${{ d }}.{% if c < 10 %}0{% endif %}{{ c }}
```

appears 8× (with different inputs and target names), each compiling to ~6
statements ≈ ~250B of ISeq. Deduplicating repeated statement RUNS into one
artifact-local lambda saves (occurrences−1) × (run size − call size). Estimate
for email: ~7 × ~180B ≈ 1.2–1.5KB. This generalizes: every big real template
(cart, product page) has copy-pasted blocks.

## Where this happens

All work is on the IL, inside lib/liquid_il/ (the standing directive: never
analyze or rewrite generated Ruby text — decide on `@instructions`, thread
into codegen; see the Effects/scope_lookup pattern in ruby_compiler.rb).
Recommended placement: a late optimizer step that runs AFTER
`fused_peephole`/const-folding (so runs are in final form) and BEFORE codegen.

## The hardest part: choosing dedup candidates SAFELY

This is where a sloppy implementation produces wrong renders. Read this
section twice.

### Step 1 — window eligibility (what may be inside a dedup run)

Scan `@instructions` for maximal runs of consecutive instructions where EVERY
instruction satisfies ALL of:

- Opcode is in an explicit ALLOWLIST. Start conservative:
  `WRITE_RAW, WRITE_VALUE, WRITE_VAR, WRITE_VAR_PATH, CONST_* (all),
  FIND_VAR, FIND_VAR_PATH, LOOKUP_CONST_KEY, LOOKUP_CONST_PATH,
  LOOKUP_COMMAND, CALL_FILTER, COMPARE, CASE_COMPARE, CONTAINS, BOOL_*,
  IS_TRUTHY, ASSIGN, ASSIGN_LOCAL, IF, ELSE, END_IF, DUP, POP, BUILD_HASH,
  NEW_RANGE`.
  EXCLUDED and why:
  - `PUSH_INTERRUPT` (break/continue): compiles to plain Ruby `break`/`next`;
    inside a lambda those change meaning (a `break` in a lambda body returns
    from the lambda, not the enclosing loop driver block). Never allow.
  - `FOR_INIT..FOR_END`, `TABLEROW_*`: loop emission depends on the effects
    frame of the ENCLOSING context (needs_scope_sync etc.); a loop inside a
    dedup lambda changes `@loop_depth` and alias context. Disallow in v1.
  - `RENDER_PARTIAL / INCLUDE_PARTIAL / CONST_* partial ops`,
    `:SHOPIFY_SECTION_RENDER`, `:PAGINATE_*`: call-site bookkeeping
    (`@lambda_called`, cycle suffix) happens per-site at codegen. Disallow.
  - `PUSH_CAPTURE / POP_CAPTURE`, `IFCHANGED_CHECK`: capture stack `_cst` and
    `_ics` state; only allow if BOTH push and pop are inside the window —
    v1: disallow entirely.
  - `CYCLE_STEP*`, `INCREMENT/DECREMENT`: per-site identity/state keys.
    Disallow (a deduped cycle would merge distinct cycle states).
  - `LABEL / JUMP / JUMP_IF_*`: only loops produce them; disallow.
- IF-structure balance: track depth (+1 at IF, −1 at END_IF); the window must
  begin and end at the same depth AND never go below its starting depth
  (ELSE only allowed when its IF is inside the window). Trim windows to
  balanced sub-ranges rather than rejecting outright.
- Stack balance: the IL is stack-based within a statement. Only cut window
  boundaries at STATEMENT boundaries. A statement boundary is: immediately
  after `WRITE_VALUE`, `WRITE_RAW`, `WRITE_VAR`, `WRITE_VAR_PATH`, `ASSIGN`,
  `ASSIGN_LOCAL`, `END_IF` at depth 0 (relative), and before `IF` at relative
  depth 0. If unsure how statements group, mirror the walk in
  `RubyCompiler#generate_statement` — its dispatch IS the statement grammar.

### Step 2 — normalization and matching

Two runs match when their instruction sequences are identical AFTER operand
abstraction:

- Build a fingerprint per run: for each instruction, keep the opcode and all
  operands verbatim EXCEPT operands designated "parameterizable". Start with
  exactly two parameterizable kinds:
  1. the input expression name of a leading `FIND_VAR`/`FIND_VAR_PATH`
     (different money sites read different variables), and
  2. `ASSIGN`/`ASSIGN_LOCAL` target names (different sites write d/c vs
     od/oc vs td/tc).
- Collect candidate parameter positions by diffing the runs pairwise: two
  runs are compatible if they are equal at every non-parameterizable position
  and differ only at parameterizable ones, with at most 4 distinct parameter
  slots (more params erode the byte win — call-site operands cost bytes too).
- CRITICAL correctness rule for ASSIGN targets: within one run, the SAME
  target name must map to the SAME parameter slot everywhere it appears
  (definition AND subsequent FIND_VAR reads of it inside the run). If the run
  assigns `d` then reads `d`, the parameterized version must assign
  `param_slot_0` then read `param_slot_0`. If a read of `d` occurs but no
  assignment preceded it INSIDE the run, that read is an input, not a local —
  treat as parameter kind 1. Get this wrong and sites cross-contaminate.
- Only accept groups where: occurrences ≥ 3, run length ≥ 5 instructions, and
  estimated saving positive: `(occurrences - 1) * est_run_bytes -
  occurrences * est_call_bytes - lambda_overhead` with rough constants
  est_call_bytes ≈ 80 (send + operands), lambda_overhead ≈ 250 (nested ISeq),
  est_run_bytes ≈ 45 × instruction count (calibrate: compile email with and
  without one dedup and diff `to_artifact.bytesize` — replace the constants
  with measured ones in a comment).

### Step 3 — rewriting the IL and emitting

- Replace each occurrence with a new synthetic opcode, e.g.
  `[:CALL_SEQ, seq_id, [arg_operands...]]`, and register the abstracted body
  under `seq_id` on the compile result.
- Codegen: emit each sequence once, near the frozen-array constants (grep
  `generate_frozen_array_constants` for placement — sequences, like `_fa`
  constants, must be defined before the body and before partial lambdas):

  ```ruby
  _sq0__ = ->(_O, _S, __p0__, __p1__) {
    <body compiled with parameter bindings>
  }
  ```

  and at each site: `_sq0__.call(_O, _S, _S.lookup("unit_price"), "d")`.
  Parameter kind 1 (input variable) is passed as the VALUE
  (`scope_lookup("x")` at the call site — do it through scope_lookup so
  loop-var aliases and hoisted locals still apply at the site!). Parameter
  kind 2 (assign target names) is passed as the NAME STRING and used inside
  via `_H.af(_S, __p1__, ...)`.
  NOTE the subtlety this creates: inside the sequence body, reads of a
  parameterized ASSIGN target cannot use `_S.lookup("d")` — they must use
  `_S.lookup(__p1__)`. Easiest correct implementation: inside sequence
  bodies, bind an extra local at entry (`__v1__ = nil`), have ASSIGN write
  BOTH `_H.af(_S, __p1__, val)` AND `__v1__ = val`, and compile reads of that
  name to `__v1__`. That preserves observable scope state (later template
  code reads `d` from the scope) while keeping in-body reads correct and fast.
- Effects frames: compile the sequence body with the SAME RubyCompiler
  mechanisms (build_expression etc.). Record into the CURRENT effects frame
  at each CALL_SEQ site whatever the body's compilation recorded (compile the
  body once eagerly, capture its effect set, and merge it at each call site) —
  otherwise a deduped run inside a loop that reads the loop item via scope
  would break needs_scope_sync. Simplest: compile sequence bodies FIRST, save
  each body's Effects, and in generate_statement's CALL_SEQ case merge that
  Effects into `@effects.last` (reads/dynamic/open_call — same merge logic as
  pop_effects).
- Sequences interact with hoisting: compute_hoisted_lookups runs on the IL
  AFTER dedup rewriting, so CALL_SEQ arg operands contribute reads. Make the
  hoist scan treat `[:CALL_SEQ, id, args]` operands correctly: any arg that
  is a variable-read marker counts as a read; the body's writes must be
  visible to the `written` set (fold the body's ASSIGN targets in — note
  they're dynamic (parameterized names), so conservatively mark ALL names
  passed as kind-2 args at any call site as written).

### Step 4 — scope: where dedup applies

v1: main template body only, and only at top level or inside IF branches
(not inside loops — loop bodies interact with aliases; the money pattern in
email sits both inside and outside the loop, so v1 already catches ≥ 4 of 8).
v2 (only after v1 is green and measured): allow runs inside loop bodies with
the additional rule that any FIND_VAR of the loop item var becomes a kind-1
parameter passed from the alias.

## Verification gates

- `rake test` fully green (5333/0/0 baseline) — the production recordings
  and Dawn suites are the real safety net here.
- `rake bench:cold` must keep printing the hard-validation line (it renders
  every artifact and compares against fresh compile AND reference gem).
- Measure and report all four scoreboard columns before/after
  (`rake bench` + `rake liquid_vm:scenarios`): artifact and remote-hit should
  drop on email/cart/product; in-process must NOT regress more than noise
  (the lambda call per site is real render cost — if in-process regresses,
  raise the occurrence/length thresholds until it doesn't).
- Add unit tests in test/ (pattern: test/ruby_compiler_test.rb) asserting:
  (a) a template with 3+ repeated eligible blocks compiles to exactly one
  `_sq0__ = ->` definition and N calls; (b) a template where the repeated
  block contains `{% break %}` does NOT dedup; (c) repeated blocks with
  different assign targets render identically to the undeduped output —
  compare against `optimize: false` compilation output string-for-string.
