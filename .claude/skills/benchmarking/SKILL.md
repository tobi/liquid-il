---
name: Benchmarking & Optimization
description: This skill should be used when the user asks to "run benchmarks", "profile performance", "measure allocations", "optimize render speed", "find hot paths", "generate flamegraph", or mentions stackprof, memory profiler, or performance optimization.
---

# LiquidIL Benchmarking & Optimization

Guide for measuring and improving LiquidIL render performance.

## Running Benchmarks

### Official Benchmark Suite (Primary)

```bash
rake bench
```

Runs 11 real-world templates comparing liquid_ruby, liquid_il (VM), liquid_il_compiled, and liquid_il_optimized_compiled. Shows compile time, render time, and speedup ratios.

### Partials Microbenchmark (with allocations)

```bash
bundle exec ruby bench_partials.rb
```

Focused on partial rendering performance with allocation tracking. Useful for optimizing isolated scope / render tag performance.

```bash
bundle exec ruby bench_partials.rb --iterations 100    # Quick runs
bundle exec ruby bench_partials.rb --help              # All options
```

## Profiling

### CPU Profiling with Stackprof

Profile all benchmarks:
```bash
bundle exec ruby bench_partials.rb --profile stackprof --iterations 500
```

Profile a specific benchmark (recommended for focused analysis):
```bash
bundle exec ruby bench_partials.rb --profile stackprof --profile-benchmark bench_ecommerce_product_page --iterations 1000
```

View results:
```bash
bundle exec stackprof tmp/stackprof_*.dump --text --limit 30
```

Drill into a specific method:
```bash
bundle exec stackprof tmp/stackprof_*.dump --method 'ClassName#method_name'
```

Generate flamegraph:
```bash
bundle exec stackprof tmp/stackprof_*_liquid_il.dump --d3-flamegraph > tmp/flamegraph.html
open tmp/flamegraph.html
```

### Memory Profiling

```bash
bundle exec ruby bench_partials.rb --profile memory --profile-benchmark bench_ecommerce_product_page --iterations 100
```

Results saved to `tmp/memory_*.txt`.

### Render-Only Profiling

For profiling just the render phase (excluding compile time):
```bash
bundle exec ruby profile_render.rb
```

## Interpreting Stackprof Output

```
==================================
  Mode: wall(100)
  Samples: 2866 (0.00% miss rate)
  GC: 231 (8.06%)              <- GC overhead, lower is better
==================================
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
       531  (18.5%)         362  (12.6%)     #<Module:...>#__write_output__
```

- **TOTAL**: Time in method + everything it calls
- **SAMPLES (self)**: Time directly in that method
- High TOTAL, low self → optimize callees
- High self → optimize this method directly

## Optimization Workflow

1. **Establish baseline**: Run `bench_partials.rb` to get current numbers
2. **Profile hot path**: Use stackprof to identify time sinks
3. **Identify targets**: Look for high self% methods
4. **Apply optimization patterns** (see below)
5. **Verify improvement**: Re-run benchmarks and compare

## Optimization Patterns

### Replace Hash Lookups with Direct Ivars

Before:
```ruby
def capturing? = registers["capture_stack"].any?
```

After:
```ruby
def initialize
  @capture_stack = []  # Eager init
end
def capturing? = !@capture_stack.empty?
```

### Avoid respond_to? for Common Types

Before:
```ruby
def output_string(value)
  value = value.to_liquid if value.respond_to?(:to_liquid)
  # ...
end
```

After:
```ruby
def output_string(value)
  case value
  when String then value
  when Integer, Float then value.to_s
  when nil then ""
  else
    value = value.to_liquid if value.respond_to?(:to_liquid)
    to_s(value)
  end
end
```

### Eager vs Lazy Initialization

- **Hot-path arrays**: Initialize eagerly as ivars
- **Rarely-used hashes**: Lazy init with `||=`

## Key Files

| File | Purpose |
|------|---------|
| `bench_partials.rb` | Main benchmark runner with allocation tracking |
| `profile_render.rb` | Focused render-only profiling |
| `benchmarks/partials.yml` | Benchmark test cases |
| `lib/liquid_il/context.rb` | RenderScope (hot path for partials) |
| `lib/liquid_il/utils.rb` | output_string, to_s (called on every output) |
| `lib/liquid_il/ruby_compiler.rb` | __write_output__ and compiled helpers |

## Performance Targets

- **Speedup vs liquid_ruby**: 2x+ on complex templates
- **Allocations**: Comparable or fewer than liquid_ruby
- **GC pressure**: Keep under 10% of profile samples
