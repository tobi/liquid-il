# Goal 4: The concurrency story — threads audited, Ractor demonstrated

## Objective

Make "safe concurrent rendering" a verified, benchmarked, documented property
of LiquidIL — a differentiator liquid-vm (a Rust extension serializing through
its own bindings) cannot trivially match inside Ruby's model:

1. A thread-safety audit with tests that would actually catch races.
2. A concurrent-render benchmark column story (N threads, same and different
   templates).
3. A working Ractor demo: load an artifact and render inside non-main
   Ractors, with the exact supported pattern documented.
4. README section "Concurrency" documenting the guarantees and the
   compile-vs-render split.

## Current state (verified inventory, 2026-07-05)

Render-time state:
- Each render allocates its own scope (`_S`) — per-render, no sharing.
- `RuntimeHelpers` is a stateless module: module functions + frozen constants
  (`INT_TO_S`, `SPECIAL_KEYS`, `NEEDS_ESCAPE_RE`). Verify nothing mutates
  module ivars at render time (`@initialized` is set once in `init`).
- Compiled procs close over: `_H`, `_F` (module refs), `_faN__` frozen
  arrays, partial lambdas, hoisted locals (assigned once per render
  invocation — WAIT: hoisted locals and `_O` are proc-LOCAL variables
  assigned per call, not shared. But the PARTIAL LAMBDAS are created once per
  proc EVAL, shared across renders of that template — they are stateless
  closures; confirm they capture nothing mutable except the frozen constants).

Compile-time class-level state (all in lib/liquid_il/ruby_compiler.rb):
- `@@iseq_cache` (source hash → frozen binary) — check-then-write; a race
  loses a cache entry (benign) but `.clear` during concurrent read is the
  risky path. Not mutex-guarded today.
- `@@partial_cache` (source hash → compiled body info) — same pattern, plus
  compile_partial recursion. Not mutex-guarded today.
- `@@indent_partial_body_cache` — same.
- `@@frozen_array_names`, `@@partial_loop_bases` — GUARDED by
  `NAME_REGISTRY_MUTEX` (check-then-mint is not idempotent; see the comment
  at the mutex). This is the pattern to copy for the others if needed.
- Per-Context `@compile_cache` — per-instance; safe if a Context is not
  shared across compiling threads (document this as the rule OR guard it).
- `LiquidIL::TemplateCache` (lib/liquid_il/template_cache.rb) — LRU with
  byte budget; read the implementation and decide: either mutex it or
  document single-owner usage.

## Work plan

### Part 1 — thread-safety tests that can actually fail

Write test/concurrency_test.rb. Naive "spawn threads and compare output"
tests pass even on racy code; make races observable:

- Same-template hammer: ONE `Template` object, 8 threads × 500 renders each
  with per-thread distinct assigns; every output must equal that thread's
  expected string (any cross-thread bleed = shared state in the proc).
  Include a template with: loops (drivers), cycles (per-render `_cs`),
  captures (`_cst`), increment/decrement, partial lambdas, ifchanged.
- Concurrent COMPILATION hammer: 8 threads compiling 50 distinct templates
  (unique sources so caches actually mint new entries concurrently), all with
  partials sharing names but different bodies per thread — this exercises
  `@@partial_cache` / `@@frozen_array_names` / `@@partial_loop_bases` races.
  Assert each thread's rendered output matches its own template's expected
  output. Run the whole test again under `GC.stress = true` (short version)
  — it widens race windows dramatically.
- Cache-eviction race: force `@@iseq_cache` to its 1000-entry cap from
  multiple threads (unique sources) while other threads render — this hits
  the `.clear` path concurrently.
- These tests must be in the default `rake test` run but time-boxed (< 10s
  total; tune iteration counts).

Fix what the tests find. Expected fixes: wrap the three unguarded class-var
caches with either NAME_REGISTRY_MUTEX (fine — compile-time only, contention
negligible, states the comment) or per-cache mutexes; make eviction
`dup`-then-clear or just guard it.

### Part 2 — concurrent benchmark

Add `rake bench:threads`:
- Scenario: load the storefront/theme artifacts once, then render with
  1, 2, 4, 8 threads (each thread its own assigns), report renders/sec and
  scaling factor vs 1 thread. Include a mixed workload (each thread a
  different template).
- Compare against liquid_ruby under the same harness (reference liquid is
  thread-safe for rendering; the interesting number is our scaling curve —
  pure Ruby + YJIT should scale until GVL saturation; there is no C
  extension lock of our own to add contention).
- This benchmark is REPORTING, not a pass/fail gate; wire its output format
  like CacheScenarios in the Rakefile (grep `module CacheScenarios`).

### Part 3 — the hardest part: Ractor-safe rendering

Goal: demonstrate `load artifact bytes → render` fully inside a non-main
Ractor, N Ractors in parallel. This is the part that requires care; follow
this exact path and document every wall you hit.

Background facts that shape the design (verify against the Ruby version in
use, 4.0):
- A `Proc` created in one Ractor cannot be CALLED in another (procs are not
  shareable unless `Ractor.make_shareable` succeeds, which requires all
  captured state shareable — our template procs capture partial lambdas and
  frozen arrays; the lambdas capture nothing mutable, so shareability MAY be
  achievable, but do not depend on it in v1).
- Therefore v1 pattern: pass the ARTIFACT BYTES (a frozen String — shareable)
  into each Ractor; each Ractor does
  `RubyVM::InstructionSequence.load_from_binary(bytes).eval` itself and owns
  its proc. That sidesteps proc-shareability entirely. The cost (one
  iseq_load per Ractor per template, ~3µs/KB) is the same as a remote-hit —
  acceptable and honest.
- Class variables (`@@iseq_cache` etc.) are NOT accessible from non-main
  Ractors (Ruby raises `Ractor::IsolationError` / `RuntimeError: can not
  access class variables from non-main Ractors`). The RENDER path must
  therefore never touch class variables. Audit: grep `@@` under lib/ — all
  five are in RubyCompiler (compile-time). The render path to audit is:
  the generated proc body + RuntimeHelpers + Filters + Utils + drops +
  scope (context.rb). Any `@@` or lazily-initialized module ivar
  (`||=` on a module-level ivar) on that path will raise inside a Ractor —
  find them by RUNNING, not just reading: the demo script IS the audit tool.
- Frozen constants are shareable only if deeply frozen. Suspects to check
  and deep-freeze: `INT_TO_S` (array of frozen strings — ok), filter
  registries in filters.rb (any Hash constant must be frozen and hold frozen
  values), `Utils` tables, `SPECIAL_KEYS`, error-message format strings,
  `EMPTY_ARRAY`, the `FONT_WEIGHTS`-style tables in spec helpers (spec-only,
  ignore). Use `Ractor.shareable?(const)` assertions in the test.
- The ASSIGNS passed into a Ractor must be shareable (deep-frozen input data)
  or built inside the Ractor. For the demo, build assigns inside.
- Time/`now` filters use Time — fine per-Ractor.
- LiquidIL's `core_ext.rb` monkeypatches are method definitions (code, not
  state) — fine.

Deliverable: test/ractor_render_test.rb (skipped unless
`defined?(Ractor)`; Ractor warnings silenced) that:
1. Compiles a representative template (loops + filters + partials via
   `render`) on the main Ractor, gets `artifact = template.to_artifact`.
2. Spawns 4 Ractors, each receiving the frozen artifact bytes + a JSONish
   frozen env; inside each: construct the LiquidIL scope, load the iseq,
   eval, call the proc, return the output string.
   IMPORTANT: rendering an artifact needs whatever
   `LiquidIL::Template.load_artifact`/`load_and_render` does — read
   lib/liquid_il/artifact.rb and lib/liquid_il.rb (grep `load_and_render`)
   and call the SAME code inside the Ractor rather than reimplementing the
   envelope parsing. If that path touches a class-level cache, that is a
   finding: add a cache-bypassing entry point (e.g. `load_artifact(bytes,
   cache: false)`) rather than making the cache Ractor-shared.
3. Asserts all four outputs equal the main-Ractor render of the same
   template+env.
4. A variant with partials that compile at render time (dynamic includes)
   is EXPECTED to fail in v1 (render-time compilation touches
   `@@partial_cache`); assert it raises cleanly and document dynamic
   includes as main-Ractor-only for now, OR route execute_dynamic_partial's
   cache through a Ractor-local (`Ractor.current[:key] ||= {}`) — prefer the
   Ractor-local fix if it is small; it is also automatically thread-correct.
5. Do not chase 100% Ractor coverage in v1 — static templates (the
   remote-hit production shape) working inside Ractors is the headline.
   List exclusions explicitly in the README section.

### Part 4 — README

Add a "Concurrency" section: thread-safety guarantees (render: yes, shared
Template objects: yes, compile: yes with class-cache mutexes), the Ractor
pattern (code sample from the test), exclusions (dynamic includes if
excluded), and the bench:threads scaling table.

## Gates

- `rake test` fully green including the new concurrency/Ractor tests.
- `rake bench:cold` validated; `rake bench` unchanged within noise (mutexes
  are compile-time only — if a render-path mutex ever seems needed, stop and
  redesign; render must stay lock-free).
- Commit message includes the bench:threads scaling numbers.
