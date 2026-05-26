# Deferred Optimization Ideas

> **Current state**: Render at ~100µs, -90% from baseline. Plateaued after 60+ experiments.
> **Noise floor**: ~3µs. Further improvements require architectural changes.

## What Works (already implemented)
- Inline numeric comparisons (eliminated _H.cmp calls, -58µs)
- Inline property lookups (eliminated _H.lp calls, -38µs)
- Simple filter inlining (upcase, downcase → direct calls, -18µs)
- While loop for iterations (vs each block, -14µs)
- Skip __partial_scope__ for inlined partials (-38µs)
- Plus:0 identity transformation (-56µs)
- Inline round/ceil/floor with numeric args (-63µs)
- Compilation cache in Context#parse (-262µs compile)
- Safe navigation for size/length lookups (cleaner code, within noise)

## Render Path (currently ~100µs)

### Hash lookup reduction
- **Cache loop variable properties**: For properties accessed multiple times (e.g., `tags` used for both `size` check and `for` loop), generate local variable at loop start. Savings: ~2µs for tags only. Requires inter-statement analysis.
- **Use `Object` with instance variables**: Instead of Hash with string keys, use Object with `instance_variable_get` (~30ns vs ~15ns for Hash — probably slower)

### Method call reduction
- **Result caching for filters**: `UPCASE_CACHE[name] ||= name.upcase` — 8ns saving per call, ~1-2µs total. But adds unbounded cache growth. For the benchmark with 3 unique names repeated 50× each: 1.2µs saving.
- **Inline `capitalize` filter**: Like `upcase`/`downcase`, but needs to handle mixed case correctly. Already partially inlined.

### Output optimization
- **`String#concat` with multiple args**: Benchmarked as 2× slower than chained `<<`. Not viable
- **Pre-allocated output buffer**: `_O = +" " * 512` then truncate. Overhead from pre-allocation > reallocation savings
- **StringIO vs String**: `StringIO#puts` is slower than `String#<<`. Not viable
- **`tap` with block**: ~50ns overhead, 3× slower than separate `<<` calls

### Compile time (cold: 621µs, cached: 0µs)
- **Compact IL representation**: Replace arrays with packed integers or structs. Requires pipeline changes
- **Lazy partial compilation**: Defer partial compilation to first render. Only helps when partials are rarely used
- **Parser optimization**: Reduce IL instruction count via more aggressive parse-time folding

### Architecture changes (high effort)
- **C extension for hot path**: Could potentially 5-10× render speed. Major architectural change. The main candidates:
  - `RuntimeHelpers.cmp` → C function
  - `RuntimeHelpers.lookup_prop` → C function
  - Filter dispatch → C function
  - Loop iteration → C function
- **YJIT-friendly patterns**: Already using simple patterns. YJIT not available in current Ruby (4.0.5 without YJIT)
- **Different VM**: Direct IL interpretation vs generated Ruby. Generated code is 2-10× faster

### Loop optimization
- **Array#each vs while**: `while` is already the fastest (~5ns vs ~10ns per iteration)
- **`for` loop**: Syntactic sugar for `each`. Same performance
- **`times` with array access**: ~10ns per iteration. Slower than `while`

## Benchmarked And Rejected
- String fast path in output_append: noise (if check overhead = case dispatch savings)
- 2-element Array fast path in output_string: noise (length check overhead = map savings)
- Pre-fill constant args into hash literal: worse (+14µs)
- while loop with yield: noise (yield overhead = each savings)
- NUMERIC_FILTER_CALL pattern: worse (+6µs compile overhead)
- Cache Array#length in while loop: noise (length is O(1))
- Replace each with while for all loops: worse (+37µs compile overhead)
- Fast path for String in output_append: noise (is_a? adds overhead for non-String types)
- Result caching for filters: ~1-2µs saving but adds unbounded memory growth
- Method call vs proc call: 25% faster but only 11ns per render (outer call only)
- sprintf for output: 1.6× slower than <<
- concat(a,b,c): 2× slower than chained <<
- join with map: allocates 5× more objects than <<
- lambda vs proc: same speed within noise
- size vs length: same speed within noise
- safe navigation (&.) vs ternary: ~26% faster in isolation, noise in context
- Remove symbol fallback from inline loop var lookup: noise (loop vars always string-keyed)
- Conditionally load _U and _F: noise (only saves ~20ns for unused modules)
- Cache Array#length before while loop: noise (Ruby 4.0 optimizes length heavily)
- || 0 pattern for safe numeric comparisons: marginal (~1µs, within noise)
- SIMPLE_LOOP_VAR pattern for loop var output: noise (benchmark already uses inline filters)
