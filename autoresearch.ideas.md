# Autoresearch Ideas — YJIT Render Optimization

## Current Status
- Baseline: 308µs render, 1128 allocs
- Best: 280-292µs render (~9% improvement), 675 allocs (-40% reduction)
- Only 18 allocations per render of theme_product (5 String, 5 Hash, 4 ForloopDrop, 2 Array, 1 Proc, 1 Scope)

## Completed ✅
- [x] **Freeze partial spans/source** — Hoisted as frozen constants. Saved ~80 allocs.
- [x] **Freeze constant filter arg arrays** — `["large"].freeze` hoisted outside loops. Saved ~90 allocs.
- [x] **Direct `_O <<` for known-String outputs** — Skip `output_append` dispatch for `upcase`/`strip`/etc.
- [x] **Fix render scope isolation** — Dup `@static_environments` so `{% assign %}` doesn't leak into `{% render %}`.
- [x] **Eliminate per-render partial span/source allocs** — Pass via `_pc` hash arg. Saved ~40 Array allocs.
- [x] **Inline handle/handleize with tr! chain** — 4.5x faster, fewer allocs than gsub.
- [x] **INT_TO_S lookup table** — Pre-built frozen strings for integers 0-999. Saved ~13 allocs.
- [x] **Fast escape_html helper** — Skip CGI.escapeHTML when input has no special chars. Saved ~3 allocs.
- [x] **Remove wrapper proc for _pc** — Pass partial_constants directly as 4th arg.
- [x] **Optimize Scope#lookup** — Use `[]` first, only `key?` when nil. 5.8% render speedup.

## Tried, Not Helpful
- IO::Buffer — slower than String for string building
- StringIO — 30-40% slower than String `<<`
- String.new(capacity:) — slightly slower than `+""`; Ruby's geometric growth is already good
- Skip `_cst`/`_ics` in partials — too minor (2 allocs), noisy measurements
- `@context` write in apply_fast — negligible overhead with YJIT
- `ensure` block overhead — YJIT handles it well (~0ns overhead)

## Stackprof Findings (theme_product, 10K iterations)
- **GC/sweeping: ~20%** — reducing allocations is the #1 lever
- **lookup_prop_fast: 8.2%** — already JIT'd (37 blocks), hard to improve
- **String#gsub: 8.4%** — all from `handle` filter
- **compiled template body: 13.5%** — the generated code itself
- **Filters.apply_fast: 2.4%** — filter dispatch overhead
- **each_with_index: 2.0%** — for loop iteration

## Remaining Ideas

### High Impact (target GC overhead)
- [ ] **Reuse `__partial_args__` hash** — Allocated per partial call (`{}`). For no-arg renders, use `EMPTY_HASH`. For single-arg, could pass directly.
- [ ] **Inline `handle` filter** — `String#gsub` is 8.4% of time. Inlining `downcase.gsub(regex, "-")` avoids filter dispatch AND uses YJIT-friendly code.
- [ ] **Inline `money` filter** — Called 8 times in product template. `format("$%.2f", v / 100.0)` is simple and avoids dispatch.
- [ ] **Inline `escape` with nil guard** — Currently goes through `oa` for nil handling. Could do `(v = expr; _O << CGI.escapeHTML(v) if v)`.

### Medium Impact
- [ ] **Reduce ForloopDrop per-iteration cost** — Pool/reuse the Drop object across iterations (just reset index0)
- [ ] **Inline `assigns.each` in partials** — For 1-2 args, generate `scope.assign(k1, v1); scope.assign(k2, v2)` directly
- [ ] **Eliminate `@context` write in apply_fast** — `@context = context` / `@context = nil` on every filter call is unnecessary overhead if context is passed as parameter

### Lower Impact
- [ ] **Use `EMPTY_HASH` for `_cs` when no cycles** — Saves 1 hash alloc per partial
- [ ] **Pass `_H`/`_U` as proc parameters** — Avoid `opt_getconstant_path` per proc invocation
