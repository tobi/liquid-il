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
(Starting fresh)
