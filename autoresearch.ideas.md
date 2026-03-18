# Autoresearch Ideas — StringView String Allocation Reduction

## Summary
**String allocs: 100% reduction** — from 2,378 to 0.
**Total allocs: 10.1% reduction** — from 13,273 to 11,934.
**No speed regression** — parse_µs at or below baseline.

## Completed Techniques

### String allocs (2,378 → 0)
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
11. Paginate tag byte scanning — first-class parser method
12. When clause byte scanning — comma/or splitting by bytes
13. Cycle identity hash-based key — avoids join allocation
14. Fixed tag length bugs (unless=6, endpaginate=11)
15. Removed intern collision verification — FNV-1a+length = 40 bits

### Total allocs (13,273 → 11,934)
16. cache_tag_args_region! — set ivars directly, no Array return
17. parse_block_body ivar returns — @_bb_tag/@_bb_blank/@_bb_raws
18. Frozen end-tag constants — ET_ELSIF_ELSE_ENDIF etc.
19. Frozen lookup arrays — COMMAND_PROPS, RENDER_BREAK_WORDS
20. Remove dead loop_stack — pushed/popped but never read
21. save_state uses ivars — zero-alloc backtracking
22. Lazy kw_args_builders — nil until first keyword arg
23. branch_blanks → all_blank boolean — running tracker
24. For/tablerow option results via ivars — @_fo_* namespace

## Remaining Allocs (require major refactoring to reduce)
- ~3,100 IL instruction Arrays — fundamental to IL architecture
- 579 StringView — RAW content (replaces String allocs, net neutral)
- 189 blank tracking Arrays — push_blank_raw_indices (pooling causes bugs)
- ~80 branch_raws Arrays — if/elsif/else chains (need all raws at end)
- ~114 per-parse objects — Builder, Lexer, Scanner (could pool but invasive)
- ~80 filter arg local arrays — parse_filter_args misc tracking
