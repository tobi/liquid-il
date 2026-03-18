# Autoresearch: Parse Allocation & Speed Optimization

## Objective
Minimize total object allocations (`parse_allocs`) and parse time (`parse_µs`) during Liquid template parsing. Building on zero-string-allocs foundation (StringView::Strict).

## Metrics
- **Primary**: `parse_allocs` (count, lower is better) — total object allocations during parse
- **Secondary**: `parse_µs`, `render_µs`, `string_allocs` (must stay 0)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Current Results (new benchmark: 14 specs, 43 templates, 68KB)
- **parse_allocs**: 25,169 (from 25,605 baseline, -1.7%)
- **parse_µs**: ~7,600 (~1.8% faster)
- **string_allocs**: 0

## Overall Results (from project start)
- **String allocs**: 2,378 → 0 (100% reduction)
- **Total allocs**: 13,273 → 10,460 (old benchmark, 21.2% reduction)
- **Parse speed**: ~14% faster (old benchmark)

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
11. Flat blank_raw tracking with packed integer ranges
12. Spans as start_pos integers (end_pos unused)

## Files in Scope
- `lib/liquid_il/lexer.rb`, `lib/liquid_il/parser.rb`, `lib/liquid_il/il.rb`

## Off Limits
- `lib/liquid_il/structured_compiler.rb`, `lib/liquid_il/context.rb`, `lib/liquid_il/filters.rb`
