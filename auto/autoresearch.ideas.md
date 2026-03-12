# Autoresearch: Optimization Ideas

## Render-time ideas

### Done / In progress
- [x] Loop variable aliasing: use Ruby locals instead of scope.lookup() for loop item + forloop
- [x] Convert lambdas → module methods (LOOKUP, CALL_FILTER, COMPARE, etc.)
- [x] Conditional preamble: skip unused cycle_state/capture_stack/ifchanged_state
- [x] Frozen EMPTY_ARRAY for no-arg filter calls
- [ ] Inline output_append: case String/Integer/nil directly in generated code (tested, needs benchmarking)

### To explore
- **Skip assign_local in loops when no partials**: if loop body has no include/render, skip `assign_local('forloop', ...)` and `assign_local(item_var, ...)` since we use Ruby locals already
- **Inline filter fast paths**: common filters like `escape`, `upcase`, `downcase`, `size` could be inlined as direct Ruby method calls instead of going through Filters.apply dispatch
- **ForloopDrop optimization**: make ForloopDrop a Struct or use ivars directly — benchmark `index0=` setter cost
- **Hash#fetch → Hash#[]**: in lookup_prop, `obj.fetch(key) { obj[key.to_sym] }` allocates a block. Could use `obj[key] || obj[key.to_sym]` (but nil/false values differ)
- **Scope#lookup inlining**: for simple variable lookups in non-loop context, could inline `@scopes[0][key]` directly
- **String capacity tuning**: OUTPUT_CAPACITY=8192 may be too large or small for specific templates

## Parse-time ideas

### Done / In progress
- [x] Zero-alloc TemplateLexer: cursor-based, returns symbol, stores offsets as ivars
- [x] Perfect hash keywords in ExpressionLexer: byte-level disambiguation by length + first byte
- [x] Inline whitespace skip in ExpressionLexer (byte check instead of regex)
- [ ] Fix 3 test regressions from TemplateLexer rewrite (currently at 4087 vs 4090)

### To explore
- **Deferred content extraction in parser**: parser calls `token_content` (which does byteslice+strip) even when it only needs the tag name. Could extract tag name separately with a cheaper method
- **Skip optimization passes**: currently skipping passes 16-19, but there may be other passes that are expensive and low-value for structured compiler
- **Smaller generated Ruby source**: shorter variable names, fewer comments → faster eval()
- **Cache compiled partials**: if same partial is included multiple times, compile once
- **Lazy partial compilation**: only compile partials when first rendered, not at parse time

## Links & Inspiration
- [tenderlove: Fast Tokenizers with StringScanner](https://tenderlovemaking.com/2023/09/02/fast-tokenizers-with-stringscanner/) — zero-alloc lexer patterns, byte lookup tables, perfect hashing, skip vs scan, deferred string extraction
- Ruby YJIT: method calls are cheaper than lambda.call; case/when is well-optimized
- `getbyte` + `byteslice` are the fastest string access patterns in Ruby (no encoding overhead)
- `| 32` trick for case-insensitive ASCII byte comparison (only works for a-z/A-Z)

## Searches worth doing
- How does Liquid Ruby's lexer work? Compare allocation counts
- Profile with `ruby-prof` or `stackprof` to find actual hotspots in the 9 benchmark templates
- Check if `eval` of generated code could be replaced with `RubyVM::InstructionSequence.compile` for faster compilation
- Look at how Shopify's liquid-c extension achieves its performance
