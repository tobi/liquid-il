# Autoresearch Ideas Backlog

## Current State (honest, no overfitting)
- Render: 464µs → ~387µs (16.6% improvement)
- Parse: 5338µs → ~4714µs (11.7% improvement)
- Allocs: 3432 → 3119 (9.1% fewer)

## Remaining Ideas

### Render (diminishing returns — template execution is ~104µs for themes, rest is overhead)
- **Scope.new key check accounts for 398ns/render (3.5% of render)**: Only safe way to 
  eliminate: trust caller to always provide string-keyed hashes. Not safe for general use.

### Parse
- **Array-based code generation**: generate_body builds strings with <<. Array + join was 
  27% faster for 222 parts. Would save ~50µs on product page codegen. Big refactor.
- **ISeq.compile is the floor**: Even `proc { 42 }` takes 3.3µs. Simple templates spend 
  11µs in eval out of 18.7µs total parse. Can't go below this without caching.

## Tried & Discarded (don't retry)
- Fused oa_lf method (YJIT already inlines two calls efficiently)
- Scope#lookup avoiding key? (YJIT optimizes key? better than != nil)
- Inline output_append case statement (code bloat hurts parse > render benefit)
- First-key-only heuristic for string check (unsafe, increased allocs)  
- Constant preamble aliases (preamble overhead > shorter ref savings for simple templates)
- String.new capacity for codegen buffers (Ruby handles growth efficiently)
- Cache enabled-skip_passes Set (cache overhead > subtraction cost)
- trust_string_keys (benchmark overfitting)
- Hardcoded Shopify filter list (overfitting, bypassed error handling)
