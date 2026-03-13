# Autoresearch: Shopify Benchmark Optimization

## Objective
Optimize render performance of the liquid_il_shopify.rb benchmarks. These benchmarks exercise Shopify-specific filters (money, img_url, handle, etc.) and realistic theme templates (blog, cart, collection, product, search pages) with YJIT enabled.

Current baseline (YJIT, Ruby 4.0.1):
- Parse: ~5.3ms total
- Render: ~85ms total  
- Render allocs: ~94,108 total

The render path is the main target. Most filter tests render ~2.9ms each, theme pages ~3.0-3.3ms. All tests have ~3100-3900 render allocations suggesting a fixed overhead.

## Metrics
- **Primary**: `render_µs` (total render microseconds across all 29 specs, lower is better)
- **Secondary**: `parse_µs`, `render_allocs`, `passed`

## How to Run
```bash
RUBY_YJIT_ENABLE=1 ./autoresearch.sh
```

## Files in Scope
- `lib/liquid_il/structured_compiler.rb` — Code generation (inline filters, output paths)
- `lib/liquid_il/structured_helpers.rb` — Runtime helpers (lookup, compare, call_filter, output_append)
- `lib/liquid_il/filters.rb` — Filter implementations (money, escape, to_number, etc.)
- `lib/liquid_il/utils.rb` — Utility functions (to_s, output_string)
- `lib/liquid_il/drops.rb` — Drop protocol (ForloopDrop, etc.)
- `lib/liquid_il/context.rb` — Scope/context (lookup, assign)
- `spec/liquid_il_shopify.rb` — Shopify adapter with filter definitions

## Off Limits
- Don't change liquid-spec test expectations
- Don't regress any currently-passing tests (29/29 must pass)
- Don't change the benchmark harness itself

## Constraints
- All benchmarks MUST be run with `--jit` flag and `RUBY_YJIT_ENABLE=1`
- `bundle exec liquid-spec run spec/liquid_il_shopify.rb --bench --jit` is the benchmark command
- Must maintain correctness (29/29 tests passing)
- Main liquid-spec suite should not regress

## What's Been Tried

### Key Finding: deep_copy Dominates render_µs (99.7%)
The benchmark calls `deep_copy(assigns)` per render iteration, copying the 13,347-object theme 
database. With YJIT: deep_copy=2923µs, our render=5-71µs. render_µs is 99.7% benchmark overhead.

### Kept
1. **Zero-copy Scope.new** — Share assigns hash between root_scope and static_environments 
   when keys already strings. Saves 2 allocs/render. Marginal timing improvement.
2. **Fast-path fold_const_ops** — Skip non-constant opcodes with hash lookup instead of 
   const_value() method call.
3. **ISeq.compile instead of eval** — 17% faster code compilation for large templates.
4. **Shorter variable names in generated code** — 21.2% code size reduction (16122→12590 bytes).
5. **Short method aliases** — _H.lf, _H.oa, _H.cf etc. instead of long names.
6. **Pre-computed pass flags** — Local booleans instead of Set#include? per instruction.
7. **Expr class vs keyword Struct** — 5x faster Expr allocation (biggest parse win: 4.1%).

### Cumulative Results
- Parse: 5338µs → ~4900µs (8.3% improvement)
- Render: ~85000µs (unmovable, 99.7% deep_copy overhead)
- Allocs: 94108 → 94118 (essentially unchanged)

### Discarded
- Skip dup for static_environments — No measurable impact
- Inline output_append case statement — Parse 32% slower from code bloat, render unchanged
- Avoid *args splat in Filters.apply — No measurable impact  
- Skip IL passes 1,2,3,5 — Parse 0.9% faster but breaks 362 tests in main suite
- Coalesce consecutive WRITE_RAW — Too few consecutive instances to matter

### Dead Ends
- **Scope.new optimization**: 2.45µs → 2.23µs, negligible vs 2923µs deep_copy
- **Filter dispatch optimization**: Minimal impact, deep_copy dominates
- **Generated code inlining**: Code bloat hurts parse time more than it helps render
