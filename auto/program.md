# Autoresearch: LiquidIL Structured Compiler Render Speed

## Goal
Reduce the render time of the LiquidIL structured compiler across the benchmark suite.

## Metric
**Total render time in microseconds (µs)** — **lower is better**. Summed across all 9 benchmark specs. Extracted from the `render_mean` field in the JSONL results.

## Command
```bash
./auto/bench.sh
```

## Files in Scope
You may modify ANY Ruby source file under `lib/liquid_il/` to improve render speed. Key files:

- **`lib/liquid_il/structured_compiler.rb`** (2671 lines) — Generates Ruby code from IL. The generated code IS the render hot path. Changing what code gets generated is the #1 lever.
- **`lib/liquid_il/context.rb`** — `Scope` and `RenderScope` classes, `lookup()`, `assign()`, forloop stacks, capture stacks. Called on every variable access.
- **`lib/liquid_il/filters.rb`** — `Filters.apply()` dispatches filter calls. Called for every `| filter` in templates.
- **`lib/liquid_il/utils.rb`** — `Utils.output_string()`, `Utils.to_s()` — string conversion on every `{{ output }}`.
- **`lib/liquid_il/drops.rb`** — `ForloopDrop` property access — called every iteration of every for loop.
- **`lib/liquid_il/passes.rb`** / **`lib/liquid_il/optimizer.rb`** — IL optimization passes that run at compile time but affect what the runtime sees.
- **`lib/liquid_il/compiler.rb`** — IL generation from parsed template. Compile-time only but affects IL quality.

## Architecture of the Hot Path

The structured compiler generates a Ruby `proc` that gets `eval`'d once at compile time. At render time, only that proc runs. The proc uses closure-captured lambda helpers:

```
Template render call
  → compiled_proc.call(scope, spans, source)
    → __output__ << raw strings (WRITE_RAW)
    → __output__ << __output_string__(expr) (WRITE expressions)
    → __scope__.lookup(key) (variable access)
    → __lookup__.call(obj, key) (property access like item.name)
    → __call_filter__.call(name, input, args, scope) (filter pipeline)
    → __is_truthy__.call(val) (if/unless conditions)
    → __compare__.call(left, right, op) (comparisons)
    → __to_iterable__.call(val) + ForloopDrop (for loops)
```

## Key Optimization Vectors

1. **Reduce lambda call overhead** — The helpers (`__lookup__`, `__is_truthy__`, `__call_filter__`, `__output_string__`, `__compare__`) are lambdas called via `.call()`. Inlining common cases directly into generated code avoids closure dispatch.

2. **Reduce allocations** — Currently ~300-800 render allocs per benchmark. Each allocation is GC pressure. Targets:
   - `ForloopDrop` created per loop (~1 per for)
   - String conversions in `output_string`
   - Hash/scope lookups creating intermediate strings
   - `__slice_collection__` creating segment arrays

3. **Specialize generated code** — The compiler knows types at compile time in many cases. Instead of generic `__lookup__.call(obj, "name")`, generate `obj["name"]` when obj is known to be a Hash.

4. **Reduce scope overhead** — `push_scope`/`pop_scope` and `assign_local` on every for loop iteration. Could use direct local variables instead.

5. **Filter dispatch** — `Filters.apply` uses `respond_to?` + `send` which is slow. Could generate direct method calls for known filters.

6. **String building** — `__output__ << value.to_s` patterns. Could batch small writes or use frozen string concatenation.

7. **Truthy checks** — `__is_truthy__.call(x)` is called very frequently in conditionals. Could inline `!(x.nil? || x == false)` directly.

## Constraints

- **All 9 benchmark specs must still pass** (exit code 0 from bench.sh)
- **Do NOT modify benchmark templates or test fixtures** — only Ruby implementation code
- **Correctness first** — the full test suite `bundle exec liquid-spec run spec/liquid_il_structured.rb` should not regress (but benchmarks are the gate)
- **The adapter file `spec/liquid_il_structured.rb` should not be modified**
