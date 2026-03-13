# Autoresearch Ideas Backlog

## Current State (honest, no overfitting)
- Render: 464µs → ~390µs (16% improvement)
- Parse: 5338µs → ~4690µs (12% improvement)
- Allocs: 3432 → 3119 (9.1% fewer)

## At Optimization Floor
Both render and parse have been extensively profiled and optimized:
- Render is dominated by filter implementations (string ops in date/strip_html/truncatewords)
  and fundamental method dispatch (~140ns/call). Template execution itself is ~104µs for themes.
- Parse is dominated by ISeq.compile (3.3µs floor per template, ~380µs for product page).
  IL builder allocs (516 per product page) and lexer string extraction (344) are fundamental.
- Parser allocs (257 per product page) are mostly tuples and ExpressionLexer objects — fundamental.

## No remaining actionable ideas.
All known paths have been explored over 62 experiments.
