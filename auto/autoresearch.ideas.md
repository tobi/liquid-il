# Autoresearch: Optimization Ideas

## Current numbers (end of session)
- **Render**: 324-328µs (started 433µs, **-24%**, target 384µs liquid-vm — **beaten by 15%**)
- **Parse**: 6,187µs (started 7,833µs, **-21%**, target 1,490µs — still 4.2x slower)
- **Render allocs**: 1,350-1,356 (started 2,457, **-45%**, target 741 — 1.8x more)
- **Parse allocs**: 21,550 (started 27,400, **-21%**)

## Render-time — Done ✅
- [x] Loop variable aliasing: Ruby locals instead of scope.lookup()
- [x] Convert lambdas → module methods (LOOKUP, CALL_FILTER, etc.)
- [x] Conditional preamble: skip unused cycle_state/capture_stack/ifchanged_state
- [x] Frozen EMPTY_ARRAY for no-arg filter calls
- [x] Skip to_s.downcase in Filters.apply
- [x] Lazy seen={} in Utils.to_s and inspect (-314 allocs, -6% render!)
- [x] Skip assign_local in loops without partials/nested loops
- [x] Scope#stringify_keys: dup when all keys already strings
- [x] Skip ForloopDrop when body doesn't reference forloop (-6.6% render!)
- [x] Skip catch(:loop_break) when body has no break/continue
- [x] lookup_prop_fast: skip SPECIAL_KEYS check for non-special keys
- [x] Avoid fetch block alloc in lookup_prop_fast
- [x] Alias LiquidIL::StructuredHelpers→_H, Utils→_U in generated code (-26% render allocs!)

## Parse-time — Done ✅
- [x] Zero-alloc TemplateLexer (cursor-based, byte scanning)
- [x] Perfect hash keywords in ExpressionLexer
- [x] Inline whitespace skip in ExpressionLexer
- [x] Lazy tag_name extraction with frozen common-tag lookup
- [x] Skip 15 of 23 optimizer passes (only 1,2,3,4,5,7,9,20 needed)
- [x] Alias long module names in generated code (smaller eval source)

## Discarded ❌
- Inline output_append String ternary — larger generated code hurts parse
- Inline Hash fast-path in generated code — same issue
- Reduced OUTPUT_CAPACITY — resizing overhead for larger templates
- dig2/dig3 for multi-level paths — block alloc overhead cancels out
- Scope#lookup fetch with sentinel — YJIT already optimizes key?+[]
- Shared @buf for codegen — marginal, sub-methods still create strings
- String.new(capacity:) for sub-method buffers — overhead exceeds benefit
- Cache token_content — only requested once per token

## Still worth exploring (high to low impact)

### Parse (big gap remains: 6.2ms vs 1.49ms target)
- **ExpressionLexer on source bytes**: instead of extracting content string then creating ExpressionLexer(content), have ExpressionLexer work on source[content_start..content_end] range directly. Saves byteslice+strip per TAG/VAR token.
- **Reduce IL instruction allocations**: each instruction is `[:FIND_VAR, "products"]` — Array allocation. Could use Struct or encode as integers.
- **Profile eval()**: at ~90µs per template, eval is 25%+ of parse time. Could investigate `RubyVM::InstructionSequence` options or proc caching.
- **Merge lex+parse into single pass**: currently TemplateLexer extracts tokens, then Parser processes them. A single-pass parser that scans bytes directly could be faster.

### Render (diminishing returns, but allocs gap remains: 1,350 vs 741)
- **Inline filter dispatch for safe filters** (join, sort, replace, etc.) via filter_send — needs correct error handling wrapper preserving line numbers
- **Skip set_for_offset when no offset:continue** — needs global analysis of all loops
- **Profile per-benchmark**: identify which of the 9 benchmarks contributes most to the total and optimize specifically for that

## Key insights
1. **Default `= {}` arguments are silent killers** — Utils.to_s's `seen = {}` was -314 allocs, -6% render
2. **Skipping unused work at codegen time** is the highest-leverage pattern — ForloopDrop, assign_local, catch/throw each saved 2-6%
3. **Local variable > constant chain** — aliasing `LiquidIL::StructuredHelpers` to `_H` saved 26% allocs because YJIT resolves locals faster
4. **Most IL optimizer passes are redundant** with the structured compiler — we cut from 23 to 8 passes
5. **Zero-alloc lexer patterns** from tenderlove work: byte tables, skip not scan, deferred extraction
