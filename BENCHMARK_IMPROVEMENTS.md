# Benchmark Improvement Suggestions for liquid-spec

## The Core Problem: deep_copy Dominates render_mean

The current benchmark measures `render_mean` as the per-iteration time of:

```ruby
render_times = benchmark_operation(duration_seconds / 2.0) do
  LiquidSpec.do_render(deep_copy(assigns), render_options, context)
end
```

For the Shopify benchmarks, the `assigns` hash is the full theme database (13,347 objects — 9,638 hashes + 3,709 arrays). The `deep_copy` of this structure takes **2,923µs per iteration with YJIT**, while actual template rendering takes **5–71µs**.

This means **render_mean is 97–99.8% deep_copy overhead**, not template execution time.

### Evidence

| Component | Time (YJIT) | % of render_mean |
|-----------|-------------|-----------------|
| `deep_copy(assigns)` | 2,923µs | 97.6% |
| `Scope.new(assigns)` | 2.2µs | 0.1% |
| Template execution (money filter) | 5µs | 0.2% |
| Template execution (blog page) | 41µs | 1.4% |
| Template execution (product page) | 71µs | 2.4% |

The `render_allocs` metric is similarly dominated: 3,135 of ~3,142 allocations per render come from `deep_copy`.

### Why This Matters

1. **Optimizations are invisible**: A 50% speedup in template execution saves ~35µs on the product page, but that's 1.2% of render_mean — below the noise floor.
2. **Wrong signal**: Adapters with faster template engines show identical render_mean because deep_copy dominates.
3. **Memory pressure distortion**: With GC disabled during benchmarking, 2.5 seconds of deep_copy creates ~2.5 million objects, causing memory pressure that affects deep_copy's own performance unpredictably.

## Suggested Improvements

### 1. Separate deep_copy from render timing (highest impact)

```ruby
# Current: deep_copy included in timing
render_times = benchmark_operation(duration) do
  LiquidSpec.do_render(deep_copy(assigns), render_options, context)
end

# Proposed: pre-copy assigns, time only render
copies = Array.new(estimated_iterations) { deep_copy(assigns) }
copy_idx = 0
render_times = benchmark_operation(duration) do
  LiquidSpec.do_render(copies[copy_idx % copies.length], render_options, context)
  copy_idx += 1
end
```

This pre-allocates copies and measures only the adapter's render time. Each iteration still gets a fresh copy (no shared state), but deep_copy cost is excluded.

**Trade-off**: Uses more memory upfront. Could pre-allocate in batches (e.g., 100 copies at a time) to bound memory.

### 2. Report render_mean_exclusive (complementary metric)

Keep the current `render_mean` for backward compatibility, but also report a `render_mean_exclusive` that subtracts measured deep_copy time:

```ruby
# Measure deep_copy cost once
dc_times = benchmark_operation(1.0) { deep_copy(assigns) }
dc_mean = dc_times[:mean]

# Report both
result[:render_mean] = render_times[:mean]           # includes deep_copy (backward compat)
result[:render_mean_exclusive] = render_times[:mean] - dc_mean  # just template execution
```

### 3. Scale assigns to template complexity

Simple filter tests like `{{ 19900 | money }}` don't need the full 13,347-object theme database. The database is loaded because of `data_files` in the YAML metadata, but most filter tests don't reference any of its keys.

Options:
- Only load `data_files` for specs that actually reference the data (check template variables)
- Allow specs to override with `environment: {}` to opt out of the shared database
- Provide a `minimal_environment: true` flag that strips unused top-level keys

### 4. Measure render_allocs excluding deep_copy

```ruby
# Current: includes deep_copy allocations
alloc_before = GC.stat(:total_allocated_objects)
LiquidSpec.do_render(deep_copy(assigns), render_options, context)
render_allocs = GC.stat(:total_allocated_objects) - alloc_before

# Proposed: measure deep_copy and render separately
copied = deep_copy(assigns)
alloc_before = GC.stat(:total_allocated_objects)
LiquidSpec.do_render(copied, render_options, context)
render_allocs = GC.stat(:total_allocated_objects) - alloc_before
```

This gives the actual allocation count of the adapter's render path (~15 for LiquidIL) instead of the deep_copy-dominated count (~3,135).

### 5. Consider COW (copy-on-write) assigns

Instead of deep_copy, wrap assigns in a COW proxy that only copies on mutation:

```ruby
class COWHash < Hash
  def []=(key, value)
    # First mutation triggers a shallow copy
    unless @copied
      replace(super_dup)
      @copied = true
    end
    super
  end
end
```

Most templates only read from assigns (lookups), never write back. A COW wrapper would make render timing reflect actual template cost, while still protecting against cross-iteration state leakage.

## Summary

The current benchmark is excellent for correctness testing and comparing adapters at the macro level. But for optimization work, the render timing is a measure of Ruby's hash copying speed, not template engine performance. Separating deep_copy from render timing would make the benchmark **actionable for optimization** — currently, a 10x template speedup would show as a <3% improvement in render_mean.
