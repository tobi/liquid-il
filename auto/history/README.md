# Autoresearch History

Performance optimization sessions tracked via autoresearch, an automated experiment loop that benchmarks changes against the liquid-spec suite (9 templates, YJIT, 5s/spec).

## Timeline

### Benchmark progression

| Commit | Date | Parse (ms) | Render (µs) | Parse allocs | Render allocs |
|--------|------|-----------|-------------|-------------|--------------|
| `1015b60` | Mar 11 | 9.58 | 449 | 40,744 | 2,579 |
| `a7e9dc9` | Mar 12 (pre-session) | 7.83 | 451 | 27,400 | 2,579 |
| `0bec7d4` | Mar 12 (post-session) | **6.13** | **328** | **20,564** | **1,356** |

**Target:** liquid-vm at 1.49ms parse, 384µs render, 741 render allocs.

### Session 1: render-speed (Mar 11)

Branch: `autoresearch/render-speed-2026-03-11`

First autoresearch session. Focused on compile+render combined time. Key wins:
- Fused peephole optimizer passes (23→fewer iterations)
- Lazy Scope register initialization
- Eliminated push_scope/pop_scope in for loops
- Cached top_scope for hot-path lookup
- Extracted shared helper lambdas to avoid re-parsing per eval

**Files:** [`2026-03-11-render-speed-program.md`](2026-03-11-render-speed-program.md), [`2026-03-11-render-speed-bench.sh`](2026-03-11-render-speed-bench.sh)

### Session 2: bench-speed (Mar 12)

Branch: `autoresearch/bench-speed-2026-03-12` → merged as PR #3

28 experiments. Switched primary metric from render to parse mid-session.

**Render: 451µs → 328µs (−27%)**
- Lazy `seen={}` in Utils.to_s — default arg allocated hash every call (−6%, −314 allocs)
- Skip ForloopDrop when body doesn't reference forloop (−6.6%)
- Loop variable aliasing: Ruby locals instead of scope.lookup() (−2.3%)
- Lambdas → module methods: method dispatch faster than lambda.call in YJIT (−1.9%)
- Skip assign_local/catch/throw in simple loops (−1.5%)
- Alias `LiquidIL::StructuredHelpers` → `_H` in generated code (−26% allocs)
- `lookup_prop_fast`: skip SPECIAL_KEYS check + avoid fetch block alloc
- Scope#stringify_keys: dup when all keys already strings
- Filters.apply: skip to_s.downcase for already-lowercase names

**Parse: 7.83ms → 6.13ms (−22%)**
- Zero-alloc TemplateLexer: cursor-based, byte scanning (tenderlove patterns)
- Perfect hash keywords in ExpressionLexer: byte-level dispatch, no .downcase
- Skip 15 of 23 optimizer passes (structured compiler handles them)
- `extract_tag_args`: byte-scan source directly, skip token_content+split
- Lazy tag_name with frozen common-tag lookup

**Files:** [`2026-03-12-bench-speed.jsonl`](2026-03-12-bench-speed.jsonl) (full experiment log), [`2026-03-12-bench-speed-ideas.md`](2026-03-12-bench-speed-ideas.md) (ideas + learnings)

## Key Insights

1. **Default `= {}` arguments are silent killers** — `Utils.to_s(obj, seen = {})` allocated a fresh hash on every call. Changed to `= nil` + lazy `|| {}`. Single biggest alloc win.
2. **Skip work the template doesn't need** — ForloopDrop, assign_local, catch/throw, optimizer passes all conditionally skipped based on template analysis. Each saved 2-6%.
3. **Local variable > constant chain** — aliasing `LiquidIL::StructuredHelpers` to `_H` in generated code cut 26% of render allocs because YJIT resolves locals faster than constant chains.
4. **Zero-alloc lexer patterns** from [tenderlove's StringScanner article](https://tenderlovemaking.com/2023/09/02/fast-tokenizers-with-stringscanner/): byte lookup tables, skip not scan, deferred string extraction, perfect hashing for keywords.
5. **Inlining in generated code is a trap** — larger source → slower eval() → net regression. Keep generated code compact; optimize the helper methods instead.
