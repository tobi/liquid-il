# Autoresearch: liquid-spec Benchmark Speed

## Objective
Optimize LiquidIL's parse+render performance on the liquid-spec benchmark suite (9 templates covering real-world Liquid patterns: e-commerce pages, loops with filters, partials, email templates).

### Target numbers (liquid-vm, the competition)
- **Parse**: 1.49ms total (9 specs)
- **Render**: 384µs total (9 specs)
- **Render allocs**: 741

### Current numbers (liquid_il)
- **Parse**: 6.8ms total (4.6x slower than liquid-vm)
- **Render**: 524µs total (1.4x slower than liquid-vm)
- **Render allocs**: 2,579

Render is already 1.5x faster than liquid_ruby (856µs). Parse is the big gap.

## Metrics
- **Primary**: `render_µs` (total render time across 9 benchmarks, lower is better)
- **Secondary**: `parse_µs` (total parse time), `render_allocs`, `parse_allocs`

## How to Run
```bash
./auto/autoresearch.sh
```
Outputs `METRIC name=number` lines. Uses YJIT. Takes ~50s (9 specs × 5s each + overhead).

## Files in Scope
- `lib/liquid_il/structured_compiler.rb` — IL→Ruby codegen (hottest for render quality)
- `lib/liquid_il/structured_helpers.rb` — Runtime helpers called by generated code
- `lib/liquid_il/context.rb` — Scope/variable lookup (hot path for render)
- `lib/liquid_il/compiler.rb` — IL compiler + optimization passes (parse time)
- `lib/liquid_il/parser.rb` — Liquid→IL parser (parse time)
- `lib/liquid_il/lexer.rb` — Tokenizer (parse time)
- `lib/liquid_il/il.rb` — IL instruction definitions + linker (parse time)
- `lib/liquid_il/passes.rb` — Optimization pass registry (parse time)
- `lib/liquid_il/filters.rb` — Filter implementations (render time)
- `lib/liquid_il/utils.rb` — Output formatting utilities (render time)
- `lib/liquid_il/drops.rb` — Drop protocol for objects (render time)

## Off Limits
- `spec/` — adapter files
- `test/` — test files (must still pass after changes)
- Don't change the liquid-spec benchmark templates themselves

## Constraints
- `bundle exec rake unit` must pass (221 tests)
- `bundle exec liquid-spec run spec/liquid_il_structured.rb` must not regress (4057+ passing)
- YJIT must be enabled for benchmarks

## Architecture Notes

### Parse pipeline
Source → Lexer (StringScanner) → Parser (recursive descent) → IL instructions → Optimizer (20+ passes) → Linker → StructuredCompiler (IL→Ruby proc) → eval

The structured compiler is the bottleneck in parse — it reconstructs control flow from flat IL, builds expression trees, and generates Ruby source that gets eval'd.

### Render pipeline
The generated Ruby proc executes directly. It calls into:
- `Scope#lookup` / `Scope#assign` for variable access
- `StructuredHelpers.lookup_prop` for property access
- `StructuredHelpers.output_append` for output buffering
- `Filters.apply` for filter dispatch
- `StructuredHelpers::COMPARE`, `IS_TRUTHY`, `CONTAINS` etc. for conditionals

### Hot render paths (by benchmark analysis)
- `bench_online_store_page`: partials + filters (143µs, 583 allocs)
- `bench_collection_with_filters`: heavy filter chains (169µs, 487 allocs)
- `bench_product_grid`: nested loops + forloop drop (118µs, 464 allocs)

## What's Been Tried
(Starting fresh — update as experiments accumulate)
