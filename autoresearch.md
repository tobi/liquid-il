# Autoresearch: Parse Allocation & Speed Optimization

## Objective
Minimize total object allocations (`parse_allocs`) and parse time (`parse_µs`) during Liquid template parsing. Building on the zero-string-allocs foundation (StringView::Strict), now targeting the remaining ~11,934 allocations — Arrays (IL instructions, blank tracking), StringViews (RAW content), and per-parse objects.

## Metrics
- **Primary**: `parse_allocs` (count, lower is better) — total object allocations during parse
- **Secondary**: `parse_µs` (must not regress), `render_µs` (should not regress), `string_allocs` (must stay 0)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines via `auto/parse_and_metrics.sh`.

## Files in Scope
- `lib/liquid_il/lexer.rb` — TemplateLexer + ExpressionLexer
- `lib/liquid_il/parser.rb` — consumes lexer values, passes strings to IL builder
- `lib/liquid_il/il.rb` — IL builder, stores instruction operands

## Off Limits
- `lib/liquid_il/structured_compiler.rb` — code generator, consumes IL
- `lib/liquid_il/context.rb` / `lib/liquid_il/filters.rb` — runtime
- Benchmark infrastructure (`auto/`, `spec/`)

## Constraints
- `auto/checks.sh` must pass (liquid-spec: 0 errors, ≤2 known failures)
- `string_allocs` must stay at 0
- `parse_µs` must not regress (baseline ~3062µs)
- `render_µs` should not regress (baseline ~194µs)

## Allocation Baseline
Total parse allocs at start of this phase: **11,934**

Known allocation categories:
- ~3,100 Array — IL instruction tuples (fundamental architecture)
- ~579 StringView — RAW content (replaced String allocs)
- ~189 Array — blank_raw_indices tracking (pooling causes bugs)
- ~80 Array — branch_raws in if/elsif/else chains
- ~114 per-parse objects — Builder, Lexer, Scanner instances
- ~80 Array — filter arg tracking

## Prior Work (string_allocs phase)
String allocs reduced from 2,378 → 0 (100%). See git history for details.
Key techniques: region-based scanning, FNV-1a interning, byte-scanning tag parsing,
StringView::Strict for RAW content, class-level shared intern table.
