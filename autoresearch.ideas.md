# Autoresearch Ideas — Parse Allocs & Speed Optimization

## Current State (27 experiments)
- **parse_allocs**: 10,460 (down **12.3%** from 11,933 baseline)
- **parse_µs**: ~2,800 (down **~14%** from 3,268 baseline)
- **render_µs**: ~183 (down **~4%** from 190 baseline)
- **string_allocs**: 0 (maintained from prior phase)
- **Total allocs since project start**: 13,273 → 10,460 (**21.2% reduction**)

## Key Wins This Phase
1. ✅ Spans as integers (-302 allocs)
2. ✅ Flat blank_raw tracking (-174 allocs)
3. ✅ FIND_VAR_PATH inline fusion (-431 allocs)
4. ✅ WRITE_VAR/WRITE_VAR_PATH parse-time fusion (-85/-312 allocs)
5. ✅ Path array interning (~-204 on warm cache)
6. ✅ byteindex for raw + liquid token scanning (~15% speed)
7. ✅ Eliminate StringScanner (-13 allocs)
8. ✅ Fast-path parse_expression for identifiers (-96 allocs, ~5% speed)

## Remaining Budget (~10,460 allocs)
- ~2,131 IL instruction arrays — fundamental architecture
- ~579 StringView::Strict — RAW content
- ~367 LABEL arrays — fundamental (mutable, can't pool)
- ~317 path arrays — interned on warm cache
- ~190 per-parse objects — Parser, Builder, ExpressionLexer, TemplateLexer
- ~6,876 Ruby internals (T_IMEMO etc.)

## Possible Future Work (diminishing returns)
- **Flat bytecode encoding**: Eliminate ~2,131 instruction array allocs. Major architecture change.
- **Label-free IL**: Side-table positions, skip LABEL instructions. Saves ~367 allocs but breaks compiler passes.
- **IS_TRUTHY elimination**: 82 redundant IS_TRUTHY instructions could be skipped. Requires structured_compiler changes (off-limits).
- **More expression fast paths**: STRING, NUMBER, keyword literals. Marginal benefit.

## What Didn't Work
- **Pooling Builder/Lexer**: Breaks nested parsing (partials)
- **Fusing var paths via slice!**: O(n) cost outweighs savings
- **Array pool for blank_raw_indices**: Use-after-free in nested blocks
