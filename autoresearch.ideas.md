# Autoresearch Ideas — Parse Allocs & Speed Optimization

## Current State (21 experiments)
- **parse_allocs**: 10,570 (down **11.4%** from 11,933 baseline)
- **parse_µs**: ~2,930 (down **~10%** from 3,268 baseline)
- **render_µs**: ~183 (down **~4%** from 190 baseline)
- **string_allocs**: 0 (maintained from prior phase)

## Key Wins This Phase
1. **Spans as integers** (-302 allocs): Only start_pos stored, end_pos was never read
2. **Flat blank_raw tracking** (-174 allocs): Packed integer ranges instead of Array-per-block
3. **FIND_VAR_PATH inline at parse time** (-431 allocs): Build path arrays directly in parse_variable_lookup instead of N separate LOOKUP_CONST_KEY instructions
4. **WRITE_VAR/WRITE_VAR_PATH parse-time fusion** (-85/-312 allocs): In-place opcode swap eliminates WRITE_VALUE instruction
5. **byteindex for token scanning** (~10% speed): memchr-based search for `{`, `}}`, `%}` instead of byte-by-byte or regex
6. **Path array interning**: FNV-1a hash with object_ids, ~204 cache hits per pass

## Remaining Budget (~10,570 allocs)
- ~1,241 emit1 instruction arrays — fundamental IL architecture
- ~579 StringView::Strict — RAW content (replaced String allocs)
- ~523 emit2 instruction arrays — fundamental IL
- ~367 emit_label arrays — fundamental IL
- ~317 path arrays (now interned on warm cache)
- ~266 per-parse objects — Parser, Builder, Lexer, Scanner
- ~7,250 Ruby internals (T_IMEMO, T_DATA etc.)

## What Didn't Work
- **Pooling Builder/Lexer/Scanner at class level**: Breaks nested parsing (partials create new Parsers while parent is still running). FrozenError from shared instruction arrays.
- **Fusing var paths via slice!+append**: O(n) array reindexing cost outweighs savings when called in every expression context.

## Possible Future Work
- **Flat bytecode encoding**: Replace array-of-arrays with packed integer array. Eliminates ~2,131 instruction array allocs. Major architecture change.
- **Eliminate StringScanner**: Replace with plain @pos variable. Saves 38 allocs/parse. Most scanning already uses manual byte ops.
- **Label-free IL**: Store label positions in side-table, skip LABEL instruction emission. Saves ~367 allocs.
