# Spec: Clean, Generic Ruby Compiler Optimization Architecture

## Status

Implemented in July 2026. `RubyCompiler` is now a small orchestration shell over
focused analysis, statement, expression, filter, output, loop, partial, program,
cache, and symbol-table modules. The implementation also includes `CodeFragment`
metadata, structured bound-partial lowering, bounded option-complete caches,
Artifact v2 framing, a shared render executor, and a measured large-literal pool.
The remaining unchecked review items are future optimization coverage, not missing
parts of this decomposition.

## Goal

Build a faster LiquidIL Ruby compiler that keeps the core performance wins from autoresearch while removing benchmark-specific special cases, duplicated pipelines, and generated-code string surgery.

The redesigned compiler should:

1. Preserve Liquid correctness across the full spec suite.
2. Improve broad template performance, not just one benchmark shape.
3. Keep compile-time and render-time optimizations generic and explainable.
4. Make optimization decisions from structured IR/codegen metadata, not regexes over generated Ruby source.
5. Decompose the current `RubyCompiler` god object into focused components.
6. Make caches correct by construction: explicit keys, explicit invalidation, bounded memory.

## Non-goals

- Do not add a C extension.
- Do not rely on benchmark harness changes such as enabling YJIT or increasing warmup count as product-code improvements.
- Do not optimize by recognizing exact benchmark templates, names, literals, or object shapes.
- Do not split public APIs. `Context#parse` and `Template#render` remain stable.
- Do not replace the existing IL pipeline wholesale unless a smaller staged migration fails.

## Design principles

### 1. Metadata beats string inspection

Generated Ruby must not be re-parsed with `include?`, regexes, or `gsub` to infer semantics.

Bad patterns to remove:

```ruby
body_code.include?("_F")
expr_ruby.match?(STRING_RETURN_SUFFIXES)
body.gsub("_S", "__partial_scope__")
optimize_repeated_lookups(body_code)
```

Preferred pattern:

```ruby
fragment = emitter.emit(node)
fragment.source          # Ruby string
fragment.effects         # structured metadata
fragment.value_type      # optional known output type
fragment.required_locals # helper modules/state needed by emitted code
```

### 2. One canonical representation per layer

The current prototype mixes direct Ruby-string expression generation with lingering `Expr` nodes. The replacement must choose one model.

Recommended model:

- Parser emits IL.
- IL optimizer performs semantic, source-independent rewrites.
- Ruby codegen consumes IL and emits `CodeFragment` objects.
- `CodeFragment` carries structured metadata through composition.

No separate ad-hoc expression AST should remain inside codegen unless it is the canonical codegen IR.

### 3. Optimizations should be rule-based and shape-generic

An optimization is acceptable if it is based on a reusable semantic property:

- value is known string-like,
- expression is pure,
- lookup target is loop-local hash,
- filter is identity for these constant args,
- loop does not require scope synchronization,
- partial has no dynamic name, recursion, capture, cycle, or interrupt dependency.

An optimization is not acceptable if it depends on benchmark-specific incidental details:

- literal key names such as `"tags"`,
- exact generated variable names unless they are compiler-owned symbols,
- exact generated Ruby line layout,
- exact benchmark partial names,
- exact number of warmup renders.

### 4. Optimize at the lowest correct layer

- Parse-time: syntax, constants, static partial names, literal args.
- IL-time: semantic rewrites, label/link cleanup, generic peephole optimizations.
- Codegen-time: Ruby-specific lowering decisions, local variable allocation, helper selection.
- Runtime: only genuinely dynamic behavior.

If a performance win requires recognizing a semantic pattern, prefer adding an IL opcode or metadata over post-processing generated Ruby.

### 5. Fast path and fallback must share one semantic contract

Every fast path must have a clear fallback equivalent.

Example:

```ruby
InlineLookup(hash_local, key)
# equivalent to RuntimeHelpers.lookup_prop(obj, key) under declared preconditions
```

The preconditions must be represented explicitly and tested.

## Proposed architecture

### File layout

Split `lib/liquid_il/ruby_compiler.rb` into focused modules:

```text
lib/liquid_il/ruby_compiler.rb                 # orchestration only
lib/liquid_il/ruby_compiler/code_fragment.rb   # generated source + metadata
lib/liquid_il/ruby_compiler/analysis.rb        # lookup analysis + scope effects
lib/liquid_il/ruby_compiler/statement.rb       # statement walk + conditionals
lib/liquid_il/ruby_compiler/expression.rb      # expression lowering
lib/liquid_il/ruby_compiler/output.rb          # output append policy
lib/liquid_il/ruby_compiler/filter.rb          # filter/literal/lookup lowering
lib/liquid_il/ruby_compiler/loop.rb            # for/tablerow lowering
lib/liquid_il/ruby_compiler/partial.rb         # partial planning/emission
lib/liquid_il/ruby_compiler/cache_store.rb     # bounded compiler caches
lib/liquid_il/ruby_compiler/symbol_table.rb    # bounded monotonic codegen names
lib/liquid_il/ruby_compiler/program.rb         # source serialization
```

The top-level compiler should read like this:

```ruby
def compile
  analysis = Analysis.run(instructions, context: context)
  partials = PartialCompiler.compile_all(analysis.partials, context: context, cache: cache)
  emitter = Emitter.new(instructions, analysis:, partials:, context:)
  source = emitter.emit_template.source
  proc = cache.compile_iseq(source).eval
  CompilationResult.new(proc:, source:, metadata: emitter.metadata)
end
```

No method in the orchestration file should be hundreds of lines long.

## Core data model

### `CodeFragment`

A `CodeFragment` represents generated Ruby plus metadata.

```ruby
CodeFragment = Data.define(
  :source,
  :effects,
  :value_type,
  :purity,
  :locals,
  :prelude,
  :postlude
)
```

Suggested fields:

- `source`: Ruby expression or statements.
- `effects`: set of required runtime state, e.g. `:filters`, `:utils`, `:cycles`, `:captures`, `:ifchanged`, `:scope_lookup`, `:scope_write`, `:interrupts`.
- `value_type`: optional known class/category, e.g. `:string`, `:numeric`, `:boolean`, `:array`, `:unknown`.
- `purity`: `:pure`, `:scope_read`, `:scope_write`, `:may_raise`, `:unknown`.
- `locals`: compiler-owned locals used by fragment.
- `prelude`: statements that must run before the expression.
- `postlude`: cleanup statements.

Ruby version constraints may require a simple class instead of `Data.define`; the concept matters more than the implementation.

### `AnalysisResult`

One forward scan should classify instruction features:

```ruby
AnalysisResult = Struct.new(
  :uses_filters,
  :uses_utils,
  :uses_cycles,
  :uses_captures,
  :uses_ifchanged,
  :uses_interrupts,
  :partials,
  :loops,
  keyword_init: true
)
```

This replaces repeated `body_code.include?` checks.

### `SymbolTable`

Compiler-owned Ruby local names should come from a symbol table, not string conventions sprinkled through the code.

Responsibilities:

- allocate loop item locals,
- allocate collection/index locals,
- allocate temporary values,
- know which Liquid variable maps to which Ruby local in a lexical scope,
- prevent accidental collisions.

## Generic optimization rules

### 1. Direct expression lowering

Keep the major win from autoresearch: avoid building unnecessary expression trees on the hot compile path.

But expression lowering should return `CodeFragment`, not bare strings.

Example:

```ruby
ExpressionEmitter#emit_lookup_const(obj, key)
# returns CodeFragment(source: ..., effects: ..., value_type: ...)
```

Benefits:

- output policy can choose direct `<<` from `value_type`,
- loop policy can inspect `effects`,
- helper module requirements are explicit,
- partial inliner does not need `gsub`.

### 2. Lookup lowering

Generic lookup fast paths:

1. If target is a compiler-owned loop item local known to be a Hash-like item, emit direct string-key lookup with fallback only when needed by semantics.
2. If key is a known Liquid special property (`size`, `length`, `first`, `last`, `empty`, `count`), emit a small canonical inline helper expression.
3. Otherwise call the runtime helper.

Do not recognize benchmark keys. Do not do post-generation lookup hoisting by regex.

If lookup hoisting is needed, implement it before Ruby string emission:

```ruby
LookupUsageAnalyzer.find_repeated_pure_lookups(block)
```

It should operate over IL or expression fragments, not generated lines.

### 3. Output append policy

Create one canonical output append component:

```ruby
OutputEmitter.append(fragment, guard_interrupt: false)
```

Policy:

- `value_type == :string`: emit `_O << expr`.
- `value_type == :numeric`: emit `_O << expr.to_s` if exact semantics are safe.
- otherwise: emit `_H.oa(_O, expr)`.

No regex classification of generated Ruby.

### 4. Filter lowering

Filters should be represented in a table with metadata:

```ruby
FilterRule = Struct.new(
  :name,
  :arity,
  :pure,
  :value_type,
  :identity_args,
  :inline_proc,
  :fallback
)
```

Examples:

- `plus: 0`, `minus: 0`, `times: 1`, `divided_by: 1` are identity rules.
- `upcase`, `downcase`, `capitalize`, `strip` are pure string-returning no-arg rules.
- `round`, `ceil`, `floor` are numeric-returning rules when args are safe.

The rule table should live in `ruby_compiler/filters.rb`, not as scattered `case` branches.

Each rule must specify:

- preconditions,
- generated code,
- result type,
- fallback helper.

### 5. Loop lowering

Loop lowering should classify loop requirements before emitting the loop body.

```ruby
LoopPlan = Struct.new(
  :collection,
  :item_name,
  :needs_forloop,
  :needs_scope_sync,
  :needs_interrupt_catch,
  :needs_offset_limit,
  :needs_resource_limits,
  :can_use_plain_while,
  keyword_init: true
)
```

`needs_scope_sync` must not be inferred from `body_code.include?`. It should be derived from fragment effects:

- body reads loop variable through scope,
- body writes scope,
- body calls dynamic partial,
- body needs `forloop`,
- body may propagate interrupts.

Fast path:

- collection fragment is pure enough,
- no forloop drop,
- no scope sync,
- no catch,
- no offset/limit/reversed/else,
- no resource-limit special path beyond explicit checks.

Then emit while loop.

Fallback path:

- use canonical runtime helpers and full semantics.

### 6. Partial compilation and inlining

Make RubyCompiler the canonical owner of Ruby-level partial inlining.

Partial inlining eligibility should be an explicit plan:

```ruby
PartialPlan = Struct.new(
  :name,
  :mode,
  :static_name,
  :recursive,
  :has_dynamic_args,
  :uses_cycles,
  :uses_captures,
  :uses_ifchanged,
  :uses_interrupts,
  :can_inline,
  :compiled_fragment,
  keyword_init: true
)
```

Remove string rewriting from partial inlining.

Instead, compile a partial body against a scope abstraction:

```ruby
ScopeBinding = Struct.new(:lookup_strategy, :assign_strategy)
```

For a normal partial:

- lookup strategy emits `__partial_scope__.lookup(key)`.

For an inlined isolated partial with known args:

- lookup strategy emits compiler-owned temp locals for known args,
- falls back to isolated scope only when the partial actually requires scope semantics.

This deletes the need for:

- `body.gsub("_S", "__partial_scope__")`,
- replacing `__partial_scope__.lookup(...)` strings,
- testing for `indented_body.include?("__partial_scope__")`.

### 7. Caching

All caches need explicit keys.

#### Template compile cache

Current risk: source-only cache may ignore options/context.

Key should include:

- complete immutable source value,
- strict variable/filter/error modes,
- registered custom filters version,
- tag registry version if applicable,
- file system identity/version if partials are involved,
- compiler options relevant to output.

#### Partial cache

Key should include:

- partial name,
- complete immutable source value,
- context modes,
- custom filter registry version,
- file system identity/version,
- compiler version/cache schema version.

For process-local caches, retain complete immutable String/Array keys and let
Ruby Hash bucket them; equality makes collisions harmless without extra hashing.
Cross-process body identity is supplied by the host partial index.

#### ISeq cache

Key should include:

- complete generated Ruby source,
- Ruby version,
- LiquidIL compiler version/cache schema version.

All caches must be bounded.

## Anti-overfit benchmark policy

### Benchmark matrix

The redesigned compiler must be measured across a diverse suite:

1. Static template with mostly raw output.
2. Variable interpolation only.
3. Deep property lookups.
4. Filters only.
5. Numeric filters/comparisons.
6. Simple `for` loops.
7. Loops requiring `forloop`.
8. Nested loops.
9. `break` / `continue`.
10. `render` with isolated partials.
11. `include` with shared scope.
12. Dynamic partial names.
13. Captures and `ifchanged`.
14. `cycle`.
15. Tablerow.
16. Strict variables/filters/error modes.
17. Custom filters: pure and impure.
18. Drops and non-Hash objects.
19. Hashes with string and symbol keys.
20. Large arrays and empty/nil collections.

No single benchmark should drive an optimization unless the rule helps or is neutral across this matrix.

### Measurement protocol

Report separately:

- cold compile time,
- cached compile time,
- cold render time,
- warm render time with normal warmup,
- warm render time with YJIT explicitly labeled,
- allocations.

Do not mix benchmark harness changes into product-code improvements.

Recommended metrics:

```text
compile_cold_µs
compile_cached_µs
render_cold_µs
render_warm_µs
render_yjit_warm_µs
total_cold_µs
total_cached_warm_µs
compile_allocs
render_allocs
```

### Acceptance criteria

The redesign is acceptable if:

1. Full correctness suite passes.
2. No benchmark regresses by more than 5% unless justified by correctness or broader average improvement.
3. Geometric mean across the benchmark matrix improves materially.
4. The original autoresearch benchmark retains most of the product-code win.
5. YJIT improvements are reported separately.
6. `ruby_compiler.rb` no longer grows as a god object.
7. No generated-code regex post-processing remains in the compiler hot path.

## Migration plan

### Phase 1: Safety and baseline

- Preserve current behavior.
- Add broad benchmark matrix.
- Add generated Ruby snapshot tests for representative templates.
- Add cache correctness tests.
- Add tests for partials, custom filters, strict modes, drops, and non-Hash lookups.

### Phase 2: Introduce `CodeFragment`

- Add `CodeFragment` and metadata composition.
- Convert output append to consume fragments.
- Keep existing emitted Ruby strings initially.
- Remove regex-based output type guessing once metadata is complete.

### Phase 3: Extract emitters

Move code without changing behavior:

1. [x] `OutputEmitter`
2. [x] `FilterEmitter`
3. [x] `ExpressionEmitter`
4. [x] `LoopEmitter`
5. [x] `PartialEmitter`
6. [x] `AnalysisEmitter` and `StatementEmitter`
7. [x] `CompilationCache`, `CompilerCaches`, and `CodegenSymbols`

Each extraction should preserve benchmark numbers within noise.

### Phase 4: Remove duplicate expression paths

- Convert loop/tablerow offset/limit handling to the canonical expression representation.
- Delete dead `Expr` or make it the only expression representation.
- Delete obsolete `expr_to_ruby` paths if direct fragments win.

### Phase 5: Replace partial string rewriting

- Add scope binding abstraction.
- Compile partials with explicit lookup/assignment strategies.
- Delete `indent_partial_body` string substitutions.

### Phase 6: Move semantic optimizations earlier

- Replace `optimize_repeated_lookups(code)` with IL/codegen usage analysis.
- Replace helper inclusion detection from `include?` with effect metadata.
- Replace loop capability detection from `body_code.include?` with effect metadata.

### Phase 7: Cache correctness cleanup

- [x] Replace bare `String#hash` integer identities with complete immutable keys.
- [x] Add cache schema versioning.
- [x] Include context-relevant options in keys.
- [x] Bound every cache and codegen symbol registry.

## Review checklist

Before merging the cleaned version, verify:

- [x] The orchestration compiler is decomposed into focused modules.
- [x] No generated Ruby is parsed with regex/string matching to infer semantics.
- [x] No benchmark-specific names or literal keys appear in optimization rules.
- [x] Filter optimizations live in rule tables.
- [x] Lookup optimizations have explicit preconditions.
- [x] Output append decisions use metadata, not regexes.
- [x] Loop fast paths use structured effects metadata.
- [x] Partial inlining does not use `gsub` over generated Ruby.
- [x] Cache keys include context-sensitive inputs.
- [x] Product-code wins are reported separately from YJIT/harness wins.
- [ ] Every fast path has fallback-equivalence tests.

## Distilled core ideas worth keeping

The autoresearch prototype found several strong generic ideas. Keep these, but implement them cleanly:

1. **Avoid unnecessary passes** when Ruby codegen already subsumes them.
2. **Generate direct Ruby expressions** instead of allocating temporary expression trees on the hot compile path.
3. **Use semantic IL fusion** for common lookup/write patterns.
4. **Compile partials once and reuse them**, with correct cache keys.
5. **Inline simple pure filters** through a table-driven filter rule system.
6. **Inline identity filters** for constant identity args.
7. **Lower simple loops to while loops** when structured analysis proves full scope semantics are unnecessary.
8. **Inline common property lookups** when the semantic preconditions are explicit.
9. **Avoid runtime helper dispatch** only when the generated code is provably equivalent.
10. **Track codegen effects explicitly** so preamble/helper/state generation is deterministic and maintainable.

## Final target

The final implementation should feel smaller than the prototype even if it has more files.

The target is not “a benchmark-specific Ruby string generator.”

The target is:

> a structured, metadata-driven Liquid-to-Ruby compiler with generic fast paths and explicit fallbacks.

That design should keep the speedups, make future optimizations safer, and perform well across the whole benchmark matrix instead of only the original autoresearch template.
