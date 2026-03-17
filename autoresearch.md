# Autoresearch: Parse Speed Optimization

## Objective
Optimize the full Liquid template compilation pipeline (lexing → parsing → IL → optimization → structured compilation → ISeq eval) as measured by liquid-spec's benchmark suite.

## Metrics
- **Primary**: `parse_µs` (µs, lower is better) — total parse/compile time across all benchmark templates
- **Secondary**: `parse_allocs`, `render_µs`, `render_allocs`

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Pipeline Breakdown (warm, ISeq cached)
| Stage | Time | % |
|-------|------|---|
| Lex + Parse + IL + Optimize + Link | ~5000µs | 49% |
| Structured Compile (IL → Ruby src) | ~4400µs | 43% |
| ISeq load from binary cache | ~850µs | 8% |

ISeq.compile() only runs on first call; subsequent calls use binary cache (~8% of total).
The dominant cost is **structured compilation** (building Ruby source from IL instructions).

## Files in Scope
- `lib/liquid_il/lexer.rb` — TemplateLexer + ExpressionLexer (726 lines). Already zero-alloc patterns.
- `lib/liquid_il/parser.rb` — Recursive descent parser (2301 lines). Creates ExpressionLexer per expression, uses regex for for/assign/tablerow.
- `lib/liquid_il/il.rb` — IL instruction set + Builder (451 lines). Each emit creates a new array.
- `lib/liquid_il/structured_compiler.rb` — IL → Ruby code generation (2891 lines). **43% of parse time**. Heavy Expr allocation, string interpolation.
- `lib/liquid_il/compiler.rb` — Orchestrates: parse → optimize → structured compile (1501 lines).
- `lib/liquid_il/passes.rb` — IL optimization passes.

## Off Limits
- Benchmark harness, test fixtures, spec files
- `autoresearch.checks.sh` — liquid-spec ≥4062 passed, ≤2 failures, 0 errors
- Do NOT cheat or overfit to benchmarks

## Constraints
- Tests must pass (checks.sh)
- Render performance must not regress
- Generated code must be correct

## What's Been Tried
- **Baseline**: parse 3516µs, 15651 parse allocs (current commit a816ce7)
- **ExpressionLexer reuse** (previous session): Added `reset_source()` method, reused single instance. Showed ~7% parse speedup + -586 allocs. Changes were lost to auto-revert issues. **Needs to be re-applied.**
- **Frozen zero-arg IL instruction arrays** (previous session): Pre-freeze `[WRITE_VALUE].freeze` etc. Showed -756 allocs. Also lost to reverts. **Needs to be re-applied.**
- **Assign tag regex elimination**: Replace `match(/.../)` with `String#index('=')`. Minor win.
- Previous session had difficulty with auto-revert losing changes across experiments. Key lesson: apply ALL changes atomically, verify syntax, run experiment, log immediately.
