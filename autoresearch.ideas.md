# Autoresearch Ideas — Parse Speed Optimization

## Pipeline Breakdown (49% lex/parse/IL, 43% structured compile, 8% ISeq load)

## Ready to Re-apply (proven in prior session, lost to auto-reverts)
- [ ] **Reuse ExpressionLexer** — `reset_source()` instead of `new()`. Saves ~24 object allocs. ~7% speedup.
- [ ] **Frozen zero-arg IL instruction arrays** — Pre-freeze `[WRITE_VALUE].freeze` etc. Saves ~200+ array allocs.
- [ ] **Assign tag: String#index instead of regex** — Minor alloc savings.

## High Priority — Structured Compiler (43% of parse)
- [ ] **Replace Expr Data class with lighter encoding** — 971 Expr allocations per biggest template. Could use arrays `[type, value, children]` or flat encoding.
- [ ] **Reduce string allocations in code generation** — 626 String allocs in structured_compiler. Use `String.new(capacity:)` + `<<` instead of interpolation where hot.
- [ ] **Cache structured compilation** — If IL instructions are identical (same template), cache the Ruby source string. Skip entire structured compile on cache hit.

## High Priority — Parser/Lexer (49% of parse, but includes optimizer passes)
- [ ] **Eliminate for-tag regex** — `parse_for_tag` uses 4+ regex ops + gsub. Replace with single-pass lexer-based parsing.
- [ ] **Eliminate tablerow-tag regex** — Same pattern, 6+ regex ops.
- [ ] **Avoid token_content string extraction** — `parse_raw` calls `token_content` (byteslice + strip). Could check whitespace via bytes.
- [ ] **Pre-freeze common instruction arrays for 1-arg opcodes** — e.g., `[FIND_VAR, "product"]` for common variable names.

## Medium Priority
- [ ] **Profile optimization passes** — Some passes may cost more time than they save. Selectively disable expensive ones.
- [ ] **Reduce `with_span` array allocations** — `[start_pos, end_pos]` allocated per emit. Could use flat pair encoding in spans array.
- [ ] **Avoid MatchData allocation in when-clause** — `split(/\s*(?:,|\bor\b)\s*/)` in parse_when_clause allocates array + strings.

## Lower Priority
- [ ] **Reuse Parser instance** across templates (if context allows)
- [ ] **Pre-size @instructions array** based on source length heuristic
