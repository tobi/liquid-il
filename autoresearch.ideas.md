# Autoresearch Ideas — Parse Allocs & Speed Optimization

## Current State (new benchmark: 14 specs, 43 templates, 68KB)
- **parse_allocs**: 22,168 (down **13.4%** from 25,605 baseline)
- **parse_µs**: ~7,168 (down **~7.1%** from baseline)
- **render_µs**: ~1,508 (down **~6.7%** from baseline)
- **string_allocs**: 0

## Key Wins This Session
1. ✅ Reusable path buffer for FIND_VAR_PATH (-436)
2. ✅ Pre-frozen CONST_INT/COMPARE/PUSH_INTERRUPT/STORE_TEMP/LOAD_TEMP arrays (-267)
3. ✅ Class-level instruction cache @@inst1_cache/@@inst2_cache (-1,266)
4. ✅ Cached I_NOOP + skip-rstrip optimization (-11)
5. ✅ Cache const_value results in compiler (-377)
6. ✅ Frozen empty array/hash for disabled inline_partials + cached skip_passes set (-124)
7. ✅ Reusable buffers for strip_labels + IL.link (-166)
8. ✅ Frozen I_LABEL — label IDs in spans array (-592)
9. ✅ Pool TemplateLexer + ExpressionLexer at class level (-54)
10. ✅ Fix fused_peephole self-assignment bug (-4)
11. ✅ Pre-check const arg before collect_const_values (-104)
12. ✅ Skip Hash.dup in lower_const_partial (-13)

## Remaining Alloc Budget (~22,168 total, ~4,600 from liquid_il)
From liquid_il code:
- ~1,742 emit1 arrays (WRITE_RAW 929 + JUMPs 451 + misc) — FUNDAMENTALLY UNCACHEABLE
- ~1,193 StringView::Strict — RAW content, FUNDAMENTALLY NEEDED
- ~103 emit2 arrays — FOR_NEXT (mutable labels) + misc
- ~73 for_init/tablerow_init arrays — mutable recovery labels
- ~102 collect_const_values temp arrays — recursive, can't pool
- ~62 Builder objects + their @instructions/@spans arrays
- ~62 Parser objects
- ~62 return Hashes from Compiler#compile
- ~32 merge_raw_writes allocations (Strings + Arrays from pass 9)

From off-limits code (~17,600):
- ~21,206 structured_compiler.rb (dominates!)
- ~2,157 generated IL eval code
- ~301 liquid_il.rb (Context etc.)

## Possible Future Work (severely diminishing returns)
- **Pool Parser objects**: Reset per-compile. Saves ~42 allocs. Complex — many ivars to reset.
- **Flat bytecode encoding**: Major architecture change, eliminates instruction arrays. Would affect structured_compiler (OFF-LIMITS).
- **Side-table jump targets**: Store resolved positions in Hash, not inst[1]. Would allow freezing JUMPs. Requires structured_compiler change (OFF-LIMITS).
- **Lazy Template.errors/warnings**: nil until first error. Saves ~86 allocs. Borderline off-limits.

## What Didn't Work / Low Impact
- ✗ Pooling Builder: arrays returned to caller, can't reuse
- ✗ Array pool for blank_raw_indices: use-after-free in nested blocks
- ✗ I_CONST_TRUE/FALSE in fold_const_ops: fires rarely
- ✗ unshift → push+reverse: speed-only, no alloc change
- ✗ Pre-sizing arrays: Ruby Array growth reallocs aren't counted as allocs

## StringView C Extension vs Pure Ruby Polyfill
Tested a pure Ruby polyfill for StringView::Strict (lib/liquid_il/string_view_polyfill.rb).
**Result: Identical performance.** The C extension provides zero measurable benefit under YJIT.
- Parse allocs: identical (22,109-22,112 both)
- Parse time: within noise (~2-5% variance between runs for BOTH)
- Render time: within noise
- Full liquid-spec: 4055 passed, 6 failed (same as C ext)

The polyfill is ~120 lines of Ruby implementing: new, materialize, empty?, length, getbyte,
include?, ==, hash, rstrip, lstrip, strip, inspect, to_s (raises WouldAllocate), freeze.
Activated via LIQUID_IL_POLYFILL_STRINGVIEW=1 or auto-fallback on LoadError.
