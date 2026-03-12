# Autoresearch: Optimization Ideas

## Current numbers (after 18 experiments)
- **Render**: 330µs (target was 384µs liquid-vm — **beaten by 14%**)
- **Parse**: 6,682µs (target 1,490µs — still 4.5x slower)
- **Render allocs**: 1,832 (target 741 — 2.5x more)
- **Parse allocs**: 22,053

## Render-time ideas

### Done ✅
- [x] Loop variable aliasing: use Ruby locals instead of scope.lookup()
- [x] Convert lambdas → module methods (LOOKUP, CALL_FILTER, COMPARE, etc.)
- [x] Conditional preamble: skip unused cycle_state/capture_stack/ifchanged_state
- [x] Frozen EMPTY_ARRAY for no-arg filter calls
- [x] Skip to_s.downcase in Filters.apply (names already lowercase)
- [x] Lazy seen={} in Utils.to_s and inspect (-314 allocs, -6% render!)
- [x] Skip assign_local in loops without partials/nested loops
- [x] Scope#stringify_keys: dup when all keys already strings
- [x] Skip ForloopDrop when body doesn't reference forloop (-6.6% render!)
- [x] Skip catch(:loop_break) when body has no break/continue
- [x] lookup_prop_fast: skip SPECIAL_KEYS check for non-special keys
- [x] Avoid fetch block alloc in lookup_prop_fast

### Discarded ❌
- [x] Inline output_append String ternary — larger generated code hurts parse
- [x] Inline Hash fast-path in generated code — same issue
- [x] Reduced OUTPUT_CAPACITY — resizing overhead for larger templates
- [x] dig2/dig3 for multi-level paths — ~same, block alloc overhead cancels out

### To explore (render)
- **Inline more filters via filter_send**: need better error handling wrapper that preserves line numbers. Tried but had 2 regressions from error handling differences
- **Skip assign_local cleanup at end of loop**: the restore of prev forloop/item is only needed if the loop variable name is used after the loop
- **ForloopDrop: avoid allocation for simple loops**: if forloop isn't accessed in body, skip creating it entirely
- **Reduce Hash allocations in Scope.new**: currently `stringify_keys` is called twice (static_environments + root_scope). Could share when no isolation needed
- **String#<< vs String#+**: check if output building could be faster with different strategy
- **Frozen string output for static templates**: if a template has no variables, return a frozen string constant

## Parse-time ideas

### Done ✅
- [x] Zero-alloc TemplateLexer: cursor-based, returns symbol, offsets as ivars
- [x] Perfect hash keywords in ExpressionLexer: byte-level dispatch, no .downcase
- [x] Inline whitespace skip in ExpressionLexer
- [x] Lazy tag_name extraction: frozen common-tag lookup, skip split+downcase

### To explore (parse — big gap: 7.2ms vs 1.49ms target)
- **Profile IL optimizer passes**: which passes take the most time? Could skip more
- **Reduce IL instruction allocations**: each instruction is an Array — could use a more compact format
- **Faster StructuredCompiler codegen**: string building with << instead of interpolation
- **Faster eval**: try `RubyVM::InstructionSequence.compile_option=` tweaks
- **Smaller generated Ruby**: shorter variable names, fewer comments → faster eval
- **Deferred content extraction**: parser calls token_content (byteslice+strip) even for tag names it already extracted via tag_name
- **Cache compiled partials globally**: partial compilation is expensive and repeated across templates

## Links & Inspiration
- [tenderlove: Fast Tokenizers with StringScanner](https://tenderlovemaking.com/2023/09/02/fast-tokenizers-with-stringscanner/) — zero-alloc lexer patterns
- Ruby YJIT: method calls cheaper than lambda.call; case/when well-optimized
- `getbyte` + `byteslice` are fastest string access (no encoding overhead)
- `| 32` trick for case-insensitive ASCII byte comparison
- Default argument `= {}` allocates on every call even when not used — use `= nil` and `|| {}` lazily

## Key insight from this session
**The biggest wins came from:**
1. **Eliminating sneaky default-argument allocations** — `seen = {}` in Utils.to_s was -314 allocs, -6% render. Always audit `= {}`, `= []` defaults on hot paths.
2. **Skipping unused work at codegen time** — ForloopDrop, assign_local, catch/throw all skipped when body doesn't need them. Each saved ~2-6% render.
3. **Method dispatch over lambda.call** — converting lambdas to module methods saved ~2% render.
4. **Zero-alloc lexer patterns** — from tenderlove's article: byte tables, skip not scan, deferred extraction.
