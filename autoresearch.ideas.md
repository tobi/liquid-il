# Autoresearch Ideas — Parse Allocs & Speed Optimization

## Current State (new benchmark: 14 specs, 43 templates, 68KB)
- **parse_allocs**: 22,966 (down **10.3%** from 25,605 baseline)
- **parse_µs**: ~7,200 (down **~7%** from baseline)
- **string_allocs**: 0 (maintained from prior phase)

## Key Wins This Session
1. ✅ Reusable path buffer for FIND_VAR_PATH (-436)
2. ✅ Pre-frozen CONST_INT/COMPARE/PUSH_INTERRUPT/STORE_TEMP/LOAD_TEMP arrays (-267)
3. ✅ Class-level instruction cache for emit1/emit2 (FIND_VAR, ASSIGN, CALL_FILTER, etc.) (-1,266)
4. ✅ Cached I_NOOP in trim paths + skip-rstrip optimization (-11)
5. ✅ Cache const_value results in compiler.rb (-377)
6. ✅ Use instruction cache in compiler peephole passes (-1)
7. ✅ Frozen empty array/hash for disabled inline_partials (-62)
8. ✅ Cached skip_passes set computation (-62)
9. ✅ Reusable buffers for strip_labels (-135)

## Remaining Alloc Budget (~22,966)
From liquid_il code (~5,000):
- ~1,454 emit1 arrays (WRITE_RAW 929 + JUMPs 451 + misc) — WRITE_RAW can't cache (unique StringView), JUMPs can't cache (mutable labels)
- ~986 StringView::Strict — RAW content (fundamental)
- ~632 emit_label arrays — mutable (linker writes positions)
- ~220 collect_const_values temporary arrays — recursion prevents pooling
- ~62 Compiler objects + initialization
- ~43 per-template Parser/Builder/Lexer objects

From off-limits code (~18,000):
- ~21,206 structured_compiler.rb
- ~2,157 generated IL eval code
- ~301 liquid_il.rb (Context etc.)

## Possible Future Work (diminishing returns)
- **Side-table label resolution**: Store jump targets in a separate Hash instead of mutating [JUMP, label_id] arrays. Would allow freezing/caching JUMPs. Requires structured_compiler to read from side-table instead of inst[1] — OFF-LIMITS.
- **Flat bytecode encoding**: Pack instructions into a single Array/String (opcode bytes + args). Eliminates ALL per-instruction arrays (~3,000+ savings). Major architecture change affecting structured_compiler.
- **Lazy warnings/errors in Template.new**: nil until first warning. Saves 86 allocs (2 per template). But Template is borderline off-limits.

## What Didn't Work / Low Impact
- ✗ Pooling Builder/Lexer: breaks nested parsing (partials)
- ✗ Array pool for blank_raw_indices: use-after-free in nested blocks
- ✗ Caching const_instruction_for results: fires rarely on benchmark templates
- ✗ I_CONST_TRUE/FALSE in fold_const_ops: const folding fires rarely
- ✗ unshift → push+reverse: speed-only, no alloc change
