# Autoresearch: Parse Allocation & Speed Optimization

## Objective
Minimize total object allocations (`parse_allocs`) and parse time (`parse_µs`) during Liquid template parsing. Building on zero-string-allocs foundation (StringView::Strict).

## Metrics
- **Primary**: `parse_allocs` (count, lower is better) — total object allocations during full compile pipeline
- **Secondary**: `parse_µs`, `render_µs`, `string_allocs` (must stay 0)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Current Results (new benchmark: 14 specs, 43 templates, 68KB)
- **parse_allocs**: 22,185 (from 25,605 baseline, **-13.4%**)
- **parse_µs**: ~7,214 (**-6.5%** from baseline)
- **render_µs**: ~1,516 (**-6.2%** from baseline)
- **string_allocs**: 0

## Key Techniques
1. StringView::Strict for zero-copy RAW content
2. Region-based expression lexing (no substring extraction)
3. FNV-1a string interning (class-level, shared across parses)
4. Byte-scanning for all tag types
5. FIND_VAR_PATH inline fusion at parse time
6. WRITE_VAR/WRITE_VAR_PATH in-place opcode swap
7. Path array interning with reusable buffer
8. byteindex (memchr) for raw token + delimiter scanning
9. Eliminated StringScanner from TemplateLexer
10. Fast-path parse_expression for identifiers/strings/numbers
11. Class-level instruction cache (@@inst1_cache, @@inst2_cache) for frozen [opcode, arg] arrays
12. Pre-frozen constant instruction arrays (CONST_INT, COMPARE, PUSH_INTERRUPT, etc.)
13. Frozen I_LABEL with label IDs in spans array
14. Pooled TemplateLexer/ExpressionLexer (class-level, reset per parse)
15. Reusable buffers for strip_labels, IL.link, path building
16. Cached skip_passes set computation, const_value results in compiler

## Files in Scope
- `lib/liquid_il/lexer.rb`, `lib/liquid_il/parser.rb`, `lib/liquid_il/il.rb`, `lib/liquid_il/compiler.rb`

## Off Limits
- `lib/liquid_il/structured_compiler.rb`, `lib/liquid_il/context.rb`, `lib/liquid_il/filters.rb`
