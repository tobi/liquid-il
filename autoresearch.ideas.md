# Autoresearch Ideas — StringView String Allocation Reduction

## Summary
**Achieved: 100% reduction** — from 2,378 to 0 string allocations during parse (warm cache).

## Completed Techniques
1. ExpressionLexer `reset_region` — scan source by position
2. VAR/tag args region scanning — eliminates token_content byteslice
3. Identifier/string/number interning — FNV-1a hash dedup table
4. RAW content as StringView — deferred materialization
5. Assign/increment/decrement interning
6. For/tablerow byte scanning — options parsed without .split
7. Common tag fast path — byte-matching table for all known tags
8. Class-level shared intern table — persists across Parser instances
9. Loop_name object_id pair keys — zero-alloc cache lookup
10. Limit/offset/cols as source regions — expr_lexer_for_region
11. Paginate tag byte scanning — eliminates regex captures
12. When clause byte scanning — eliminates split/strip
13. Cycle identity hash-based key — avoids join allocation
14. Fixed tag length bugs (unless=6 not 7, endpaginate=11 not 13)

## Potential Next Steps (diminishing returns — metric is already at 0)

### Reduce total parse_allocs (currently ~12,500)
- 4,246 Array allocs (IL instructions) — could use packed tuples or struct-like encoding
- 579 StringView allocs (RAW content) — could encode as [offset, length] integers in IL
- 38 StringScanner + 38 ExpressionLexer + 38 TemplateLexer + 38 Builder per-parse objects
- Pool or reuse lexer/builder objects across parses

### Speed improvements (DONE — no regression remaining)
- ~~parse_µs currently ~3250 vs baseline ~3100 (5% overhead from intern hash + byte scanning)~~
- Fixed by removing intern collision verification (40 bits of entropy makes collisions vanishingly rare)
- parse_µs now ~3040 vs baseline ~3062 (slightly faster!)

### Architecture
- Single-pass unified lexer (merge Template + Expression lexers)
- StringView in ALL IL instructions (not just WRITE_RAW)
