# Autoresearch Ideas Backlog

## Current State  
- Render: 464µs → 373µs (19.6% improvement)
- Parse: 5338µs → ~4700µs (12% improvement)
- Allocs: 3432 → 3246 (5.4% fewer)

## Remaining Ideas (untried)

### Render
- **Extract for-loop boilerplate into helper method**: Each for loop generates ~20 lines of 
  boilerplate. A `_H.for_loop(collection, name, &block)` helper could reduce to ~5 lines, 
  saving 33% of code size AND reducing eval overhead. Theme templates have 5-6 for loops.
- **Skip set_for_offset when offset:continue not used**: Currently always called per loop, 
  creates 1 hash alloc. Would need a flag in FOR_INIT instruction.
- **Lazy @scopes array**: Don't create `[root_scope]` array until push_scope is called. 
  Use @top_scope directly. Most templates never push_scope.

### Parse
- **Extract for-loop boilerplate into helper** (same as render — dual benefit from smaller code)
- **Two-pass instruction removal in fused_peephole**: Mark deletions, compact in one sweep
  instead of O(n) delete_at per deletion. 59 deletions for product page.
- **Array-based code generation**: generate_body builds strings with <<. Array + join tested
  27% faster for 222 parts.

## Tried & Discarded (don't retry)
- Fused oa_lf method (YJIT already inlines two calls efficiently)
- Scope#lookup avoiding key? (YJIT optimizes key? better than != nil)
- Inline output_append case statement (code bloat hurts parse > render benefit)
- First-key-only heuristic for string check (unsafe, increased allocs)  
- Constant preamble aliases (preamble overhead > shorter ref savings for simple templates)
- String.new capacity for codegen buffers (Ruby handles growth efficiently)
- Cache enabled-skip_passes Set (cache overhead > subtraction cost)
