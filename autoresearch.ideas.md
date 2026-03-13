# Autoresearch Ideas Backlog

## Key Insight: deep_copy Dominates render_µs
The liquid-spec benchmark measures `render_mean` which includes `deep_copy(assigns)` of the 
13,347-object theme database. With YJIT, deep_copy takes ~2923µs per iteration, and our actual
template execution is ~5-71µs. The render_µs metric is 99.7% deep_copy overhead.

This means micro-optimizations to template execution won't move the render_µs metric.

## Ideas for render_µs improvement
- **Make Scope.new zero-copy**: If assigns are already string-keyed (common from YAML), 
  skip stringify_keys entirely. The benchmark's deep_copy already creates a fresh copy.
  Problem: Scope modifies the hash, so we need at least the root_scope copy.
- **Lazy scope initialization**: Don't create `@scopes` array until push_scope is called.
  Use @top_scope directly for single-scope case.
- **Pool/reuse Scope objects**: Between renders, reset a Scope instead of creating new one.
  Not possible with current benchmark API.

## Ideas for parse_µs improvement  
- **Cache compiled templates**: If the same source is parsed repeatedly (which the benchmark does),
  a simple hash cache would eliminate re-parsing. The benchmark calls `do_compile` in the compile
  timing loop.
- **Faster lexer**: Use StringScanner skip patterns, avoid string allocation in token extraction.
- **Faster IL generation**: Reduce intermediate allocations in parser/compiler.
- **Skip unnecessary IL passes**: The structured compiler uses `skip_passes` for partials but 
  not for the main template.

## Ideas for render_allocs reduction
- **Eliminate String.new(capacity: 8192)**: Use a pre-allocated buffer or output array joined at end.
- **Inline more filters at compile time**: money, handle, img_url could be inlined to avoid
  call_filter dispatch overhead.
- **Avoid @scopes array allocation in Scope.new**: Use a single ivar for single-scope case.
