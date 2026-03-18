# Autoresearch Ideas — Parse Allocs & Speed Optimization

## Current State
- **parse_allocs**: 10,571 (down 11.4% from 11,933 baseline)
- **parse_µs**: ~3,050 (down ~7% from 3,268 baseline)
- **string_allocs**: 0 (maintained from prior phase)

## Completed (this phase)
1. ✅ Spans as integer start_pos (not [start, end] arrays) — -302
2. ✅ Inline for_init/tablerow_init emit (skip splat) — -26
3. ✅ Flat blank_raw tracking with packed integer ranges — -174
4. ✅ Lazy warnings array — -5
5. ✅ Pool blank_raw_flat/marks at class level — -25
6. ✅ Case when/else returns via ivars — -4
7. ✅ byteindex for raw token scanning (memchr vs getbyte loop)
8. ✅ Fuse FIND_VAR→WRITE_VAR at parse time — -85
9. ✅ Fuse FIND_VAR+LOOKUP_CONST_KEY*→WRITE_VAR_PATH at parse time — -312
10. ✅ Inline FIND_VAR_PATH in parse_variable_lookup — -431
11. ✅ Intern path arrays — ~-204 on warm cache

## Remaining Allocs (~10,571 total, ~3,319 from liquid_il)
- **1,241** emit1 instruction arrays — fundamental IL
- **579** StringView::Strict — RAW content (replaced String allocs)
- **523** emit2 instruction arrays (FIND_VAR_PATH etc.) — fundamental IL
- **367** emit_label arrays — fundamental IL
- **317** path arrays — now interned on warm cache
- **266** per-parse objects (Parser, Builder, Lexer, Scanner, etc.)
- **~7,250** from Ruby internals (T_IMEMO, T_DATA, etc.)

## Ideas to Explore
- **Flat bytecode encoding**: Replace array-of-arrays with flat integer array + operand table. Would eliminate ALL instruction array allocs (~2,131). Major architecture change.
- **Label-free linking**: Store label positions in a side-table hash during parsing, skip LABEL instructions entirely. Saves 367 array allocs.
- **Parser/Builder pooling**: Reuse Parser objects across templates. Saves ~266 allocs per template. Requires careful state reset.
- **LOOKUP_CONST_KEY at parse time for keywords**: When checking `{% if x.y %}`, the FIND_VAR_PATH is emitted for `x.y`, but `LOOKUP_CONST_KEY` still happens for keywords. Could detect these.

## What Didn't Work
- **Fusing var paths in parse_variable_lookup via slice!+append**: Caused +1,357 alloc regression. The slice! on the instruction array is O(n) and the new arrays outweigh savings.
- **Array pool for blank_raw_indices**: Use-after-free bugs in nested blocks.
