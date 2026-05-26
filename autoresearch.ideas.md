# Deferred Optimization Ideas

## Render Path (currently ~100µs)

### Hash lookup reduction
- **Cache loop variable properties**: For properties accessed multiple times (e.g., `tags` used for both `size` check and `for` loop), generate local variable at loop start
- **Use `Object` with instance variables**: Instead of Hash with string keys, use Object with `instance_variable_get` (~30ns vs ~15ns for Hash — probably slower)

### Method call reduction
- **Result caching for filters**: `UPCASE_CACHE[name] ||= name.upcase` — 8ns saving per call, ~1-2µs total. But adds unbounded cache growth
- **Inline `capitalize` filter**: Like `upcase`/`downcase`, but needs to handle mixed case correctly

### Output optimization
- **`String#concat` with multiple args**: Benchmarked as 2× slower than chained `<<`. Not viable
- **Pre-allocated output buffer**: `_O = +" " * 512` then truncate. Overhead from pre-allocation > reallocation savings
- **StringIO vs String**: `StringIO#puts` is slower than `String#<<`. Not viable

### Compile time (cold: 621µs, cached: 0µs)
- **Compact IL representation**: Replace arrays with packed integers or structs. Requires pipeline changes
- **Lazy partial compilation**: Defer partial compilation to first render. Only helps when partials are rarely used
- **Parser optimization**: Reduce IL instruction count via more aggressive parse-time folding

### Architecture changes (high effort)
- **C extension for hot path**: Could potentially 5-10× render speed. Major architectural change
- **YJIT-friendly patterns**: Already using simple patterns. YJIT not available in current Ruby
- **Different VM**: Direct IL interpretation vs generated Ruby. Generated code is 2-10× faster

### Loop optimization
- **Array#each vs while**: `while` is already the fastest (~5ns vs ~10ns per iteration)
- **`for` loop**: Syntactic sugar for `each`. Same performance
- **`times` with array access**: ~10ns per iteration. Slower than `while`
