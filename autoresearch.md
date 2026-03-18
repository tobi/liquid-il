# Autoresearch: StringView — Eliminate Parse Allocations

## Objective
Use the `string_view` gem (C extension) to eliminate string allocations during Liquid template parsing. StringView provides zero-copy views into a source string — `getbyte`, `bytesize`, `length`, `empty?`, `reset!`, and `hash` are all zero-alloc. The goal is to pass StringViews through the entire lex→parse→IL pipeline, deferring materialization (`to_s`) to the latest possible point.

## Metrics
- **Primary**: `string_allocs` (count, lower is better) — String object allocations during parse (in liquid_il code only)
- **Secondary**: `parse_allocs` (total allocs), `parse_µs` (must not regress), `render_µs` (should not regress)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines via `auto/parse_and_metrics.sh`.

## Files in Scope
- `lib/liquid_il/lexer.rb` — TemplateLexer + ExpressionLexer (biggest String allocation source)
- `lib/liquid_il/parser.rb` — consumes lexer values, passes strings to IL builder
- `lib/liquid_il/il.rb` — IL builder, stores instruction operands (strings)
- `Gemfile` — already has `string_view` dependency

## Off Limits
- `lib/liquid_il/structured_compiler.rb` — code generator, consumes IL
- `lib/liquid_il/context.rb` / `lib/liquid_il/filters.rb` — runtime
- Benchmark infrastructure (`auto/`, `spec/`)

## Constraints
- `auto/checks.sh` must pass (liquid-spec: 0 errors, ≤2 known failures)
- `parse_µs` must not regress (baseline ~3062µs)
- `render_µs` should not regress (baseline ~193µs)
- StringView quacks like String for `==`, `include?`, `getbyte`, `to_s`, `hash` — but downstream consumers that need a real String must call `.to_s` or `.materialize`

## Allocation Baseline (pre-StringView)
Total parse allocs: ~9,507 per pass (38 benchmark templates)
- String: 3,708
- Array: 4,105 (IL instructions, out of scope)
- Other: ~700

### Top String allocation sites
| Allocs | Location | What |
|--------|----------|------|
| 979 | lexer.rb:732 | `scan_identifier_or_keyword` — identifier byteslice |
| 862 | lexer.rb:57 | `token_content` — byteslice extraction |
| 515 | lexer.rb:98 | `tag_name` — tag name byteslice |
| 272 | parser.rb:190 | `content.strip.empty?` in parse_variable_output |
| 272 | lexer.rb:62 | `token_content` lstrip/strip result |
| 179 | parser.rb:149 | `extract_tag_args` — byteslice |
| 103 | parser.rb:1231 | assign value_expr byteslice |
| 78 | parser.rb:980 | for-tag var_name byteslice |
| 76 | parser.rb:1230 | assign var_name byteslice |
| 74 | lexer.rb:636 | string literal scanning |
| 65 | lexer.rb:598 | number literal scanning |

## What's Been Tried
(updated as experiments run)

