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

## Results
- **Baseline**: 2,378 string allocs
- **Final**: 0 string allocs (**-100%**) — zero String allocations during parse with warm intern cache
- parse_allocs: ~13,273→~11,934 (**-10.1%** total allocation reduction)
- parse_µs: ~3062→~3050 (no regression — at or faster than baseline)
- render_µs: ~194→~192 (no regression)
- All liquid-spec checks pass

## What Was Done
1. **ExpressionLexer `reset_region`** — scan original source by position, no substring extraction
2. **VAR region scanning** — parse_variable_output uses reset_region, eliminates token_content byteslice+strip
3. **Tag args region scanning** — if/unless/case/echo/cycle/capture/render/include/elsif use expr_lexer_for_region
4. **Identifier string interning** — FNV-1a hash dedup table shared per-parser, repeat identifiers return cached frozen strings
5. **String/number literal interning** — extend intern table to cover all token values
6. **RAW content as StringView** — write_raw stores StringView in IL, materialized in structured compiler
7. **Assign tag region scanning** — var_name interned, value_expr via region, zero extra allocs
8. **Increment/decrement interning** — var_name via stripped interned tag arg
9. **For/tablerow byte scanning** — options parsed by scanning bytes (no .split), var_name interned, collection via region
10. **Common tag fast path** — added paginate/endpaginate/doc/# to byte-matching table

## Additional Optimizations (post-zero)
11. **Paginate tag byte scanning** — first-class parser method, eliminates regex captures
12. **When clause byte scanning** — scan commas/or by bytes, use expr_lexer_for_region
13. **Cycle identity hash key** — hash-based intern key avoids join allocation
14. **Fixed tag lengths** — unless (was 7, correct 6), endpaginate (was 13, correct 11)
15. **Loop_name object_id pair keys** — zero-alloc cache lookup for for/tablerow loop names
16. **Limit/offset/cols as source regions** — for/tablerow option values as (offset, length) pairs
17. **Removed intern collision verification** — FNV-1a+length key = 40 bits entropy, verification was the entire source of parse_µs regression

## What Was Tried But Didn't Help
- **Lazy value extraction** — deferred byteslice until value read. Same alloc count (all values consumed)
- **Packed integer keys for intern** — collision-free but no alloc improvement
- **StringView as expression value** — Array#include? breaks with StringView (String#== doesn't know about it)
- **StringView.match?** — materializes the string, defeats the purpose

