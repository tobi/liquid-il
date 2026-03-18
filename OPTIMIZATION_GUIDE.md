# Optimization Guide

Performance findings and future optimization paths for LiquidIL, documented during multiple autoresearch sessions.

## Current Performance (liquid-spec benchmark suite, 38 templates)

| Metric | Value |
|--------|-------|
| Parse (total) | ~3.1ms |
| Render (total) | ~210µs |
| Parse allocations | ~14,200 |
| Render allocations | ~700 |

## Parse Pipeline Breakdown

The parse/compile pipeline has three stages, measured independently:

| Stage | Time | % | Key Files |
|-------|------|---|-----------|
| Lex + Parse + IL + Optimize + Link | ~3.5ms | 41% | lexer.rb, parser.rb, il.rb, compiler.rb, passes.rb |
| Structured Compile (IL → Ruby src) | ~4.1ms | 49% | structured_compiler.rb |
| ISeq eval (load_from_binary cache) | ~0.7ms | 8% | structured_compiler.rb |

The structured compiler dominates parse time. Within the lex/parse/IL stage, optimization passes account for ~38% (1.2ms of 3.3ms).

## What's Been Optimized

### Render Path
- **Scope#lookup fast path** — `[]` first, `key?` only when nil. Avoids double hash lookup.
- **Frozen partial constants** — Spans, source strings, and filter arg arrays hoisted as frozen constants outside loops. Saves ~120 allocations per render.
- **INT_TO_S lookup table** — Pre-built frozen strings for integers 0-999. Avoids `Integer#to_s` allocation for loop indices and counts.
- **Fast escape_html** — Returns input unchanged (zero-alloc) when no HTML-special characters present. `CGI.escapeHTML` always allocates.
- **Inline comparisons** — `eq`/`ne`/`lt`/`gt`/`le`/`ge` compile to native Ruby operators with Numeric fast path, skipping the generic `compare()` dispatch.
- **Inline filters** — Common filters (upcase, downcase, strip, size, escape, url_encode, strip_html, first, last, etc.) compile to direct Ruby method calls, skipping filter dispatch overhead.
- **Skip unused preamble in partials** — Conditional allocation of cycle/capture/ifchanged state per-partial based on compile-time feature detection.
- **Direct string output** — When an expression is known to return String at compile time, skip the `output_append` type dispatch.
- **handleize optimization** — `tr!` chain replaces `gsub` (4.5x faster, fewer allocs).

### Parse Path
- **ExpressionLexer reuse** — Single `@expr_lexer` instance with `reset_source()` instead of `new()` per expression. Saves ~25 object allocations per parse.
- **Frozen zero-arg IL instruction arrays** — `I_WRITE_VALUE`, `I_PUSH_SCOPE`, etc. as pre-frozen constants. Eliminates ~200 array allocations per parse.
- **For/tablerow tag: token-based parsing** — Single-pass whitespace-split tokenizer replaces 7+ regex operations + gsub per tag.
- **Assign tag: String#index** — Replaces `match(/regex/)` with `index('=')` + `byteslice`. Avoids MatchData allocation.

## Future Optimization Paths

### Structured Compiler (49% of parse — biggest target)
- **Reduce Expr allocations** — 1,332 Expr objects per parse. The `:var` (519) and `:lookup` (433) types dominate. Could replace Expr class with Array encoding `[type, value, children, pc]` to eliminate object overhead.
- **Cache structured compilation by source hash** — If the same template is parsed multiple times, cache the Ruby source string. Skips entire structured compile on cache hit. (Legitimate for production; may mask pipeline improvements in benchmarks.)
- **Reduce string allocations in code generation** — 8,131 String allocs in structured_compiler. Use `String.new(capacity:)` + `<<` instead of interpolation in hot paths.

### Parser/Lexer (41% of parse)
- **Profile and potentially fuse optimization passes** — 8 active passes each iterate all instructions. Fusing into fewer passes reduces iteration overhead. Each pass currently costs ~150µs even when doing no transformations.
- **Avoid MatchData in when-clause** — `split(/\s*(?:,|\bor\b)\s*/)` allocates array + strings per case/when clause.
- **Pre-size @instructions array** — Heuristic based on source length to avoid array resizing.

### ISeq (8% of parse)
- **Already cached** — ISeq binary cache (`load_from_binary`) is in place. Further optimization here has diminishing returns.

### General
- **GC pressure** — ~9% of wall time is garbage collection. Every allocation reduction compounds.
- **Reduce `with_span` array allocations** — `[start_pos, end_pos]` created per IL emit. Could use flat encoding.
