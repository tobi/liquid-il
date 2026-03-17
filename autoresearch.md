# Autoresearch: Parse Pipeline Speed Optimization

## Objective
Optimize everything in the Liquid template compilation pipeline EXCEPT render.
Primary metric is `parse_µs` (total parse time from liquid-spec benchmark).
Secondary metrics break down the pipeline into stages so we can see exactly where wins come from.

## Metrics
- **Primary**: `parse_µs` (µs, lower is better) — total parse/compile time
- **Secondary pipeline breakdown**:
  - `lex_parse_il_µs` — Lex + Parse + IL emit + Optimize + Link
  - `structured_compile_µs` — IL → Ruby source code generation (StructuredCompiler)
  - `iseq_eval_µs` — ISeq load_from_binary (cache hit) or compile (cold)
- **Other secondary**: `render_µs`, `parse_allocs`, `render_allocs`

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Pipeline Architecture (warm, ISeq cached)
| Stage | Time | % | Key File |
|-------|------|---|----------|
| Lex + Parse + IL + Optimize + Link | ~5000µs | 49% | lexer.rb, parser.rb, il.rb, compiler.rb, passes.rb |
| Structured Compile (IL → Ruby src) | ~4400µs | 43% | structured_compiler.rb |
| ISeq load from binary cache | ~850µs | 8% | structured_compiler.rb (eval_ruby) |

## What's Already Committed
- **ExpressionLexer reuse** — `reset_source()` instead of `new()` per expression. -25 object allocs.
- **Frozen zero-arg IL instruction arrays** — `I_WRITE_VALUE` etc. Eliminates ~200 array allocs.
- **Assign tag regex → String#index** — Minor alloc savings.
- Combined: parse 3455→3240µs (-6.2%), allocs 15659→14144 (-9.7%)

## Constraints
- Tests must pass (checks.sh: ≥4062 passed, ≤2 failures, 0 errors)
- Render must not regress significantly
- Do NOT cheat or overfit to benchmarks
