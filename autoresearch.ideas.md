# Autoresearch Ideas — Parse Pipeline Optimization

## Pipeline Breakdown (49% lex/parse/IL, 43% structured compile, 8% ISeq load)

## High Priority — Structured Compiler (43% of parse)
- [ ] **Frozen common Expr constants** — EXPR_NIL, EXPR_TRUE, EXPR_FALSE, EXPR_ZERO, EXPR_EMPTY, EXPR_BLANK. Saves ~48 object allocs per parse.
- [ ] **Replace Expr class with Array encoding** — `[type, value, children, pc]` instead of `Expr.new(type:, value:, ...)`. Saves object header overhead on ~971 allocs.
- [ ] **Reduce string allocations in code generation** — 626 String allocs. Use `String.new(capacity:)` + `<<` instead of interpolation in hot paths.
- [ ] **Cache structured compilation by IL hash** — If IL instructions identical, cache Ruby source. Skip entire structured compile on cache hit.

## High Priority — Parser/Lexer (49% of parse)
- [ ] **Eliminate for-tag regex** — `parse_for_tag` uses 4+ regex ops + gsub. Replace with lexer-based single-pass parsing.
- [ ] **Eliminate tablerow-tag regex** — Same pattern as for-tag, 6+ regex ops.
- [ ] **Profile optimization passes** — Some passes may cost more time than they save. Selectively disable expensive ones.

## Medium Priority
- [ ] **Reduce `with_span` array allocations** — `[start_pos, end_pos]` per emit. Could push two flat values instead.
- [ ] **Avoid MatchData in when-clause** — `split(/\s*(?:,|\bor\b)\s*/)` allocates array + strings.
- [ ] **Pre-freeze common 1-arg instruction arrays** — `[FIND_VAR, "product"]` for most-used variable names.

## Lower Priority
- [ ] **Pre-size @instructions array** based on source length heuristic
- [ ] **Reuse Parser instance** across templates if context allows
