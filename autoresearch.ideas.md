# Autoresearch Ideas — YJIT Render Optimization

## Key Findings from YJIT Disasm Analysis (theme_product benchmark)

### Allocation Hotspots (337 total render allocs)
- **120 allocs**: `_sp = [...]` spans array literal in partial template — massive array created every partial call. Should be a frozen constant.
- **52 allocs**: `money` filter — string formatting
- **48 allocs**: `product_img_url` filter — string interpolation/sub
- **31 allocs**: `output_append` (`oa`) — `value.to_s` creates strings
- **132 Array objects total** — many from filter arg arrays like `["large"]` created per call
- **5 ForloopDrop objects** — one per for loop

### YJIT JIT Status
- ✅ Compiled template proc: 398 blocks, 123KB machine code
- ✅ `lookup_prop_fast` (lf): 37 blocks — hot and JIT'd
- ✅ `output_append` (oa): 20 blocks — JIT'd
- ✅ `Scope#lookup`: 28 blocks — JIT'd
- ❌ `Filters.apply`: NOT JIT'd (but `cff` bypasses it)

### Generated Code Patterns (18KB, 284 lines)
- 54x `_H.lf` (lookup_prop_fast) — most common call
- 41x `_S.lookup` — scope variable lookups
- 35x `_H.oa` (output_append) — output buffering
- 11x `_H.cff` (call_filter_fast) — filter calls
- 8x `_S.assign_local` — loop variable assignments

## Optimization Ideas

### High Impact
- [ ] **Freeze partial spans arrays** — Generate `_sp = PARTIAL_SPANS_CONST` referencing a frozen constant instead of an array literal. Saves 120 allocs (35% of total).
- [ ] **Freeze filter arg arrays** — `duparray ["large"]` allocates every time. For constant filter args, generate frozen constants. Could save 20-30 allocs.
- [ ] **Inline simple filters** — `escape`, `money`, `upcase`, `downcase`, `strip` could be inlined as direct Ruby calls instead of going through `cff` dispatch. Saves method call + arg array overhead.
- [ ] **Skip `to_s` in output_append when type is known** — If the compiler knows the expression is already a string (e.g., from a string filter), skip the type dispatch in `oa`.

### Medium Impact
- [ ] **Reduce ForloopDrop allocations** — Can forloop.index/length be tracked as plain integers instead of Drop objects?
- [ ] **Pool/reuse Scope objects** — The Scope allocates on every render. Could it be reset-and-reused?
- [ ] **Avoid `assigns.each` in partials** — Line 18: `assigns.each { |k, v| __partial_scope__.assign(k, v) }` iterates a hash. Could be a direct merge.

### Lower Impact / Exploratory
- [ ] **Remove `_cs` hash allocation** — Line 22: `_cs = isolated ? {} : ...` — cycle state hash allocated even when no cycles used
- [ ] **String capacity hints** — `_O = +""` could be `String.new(capacity: N)` based on estimated output size
- [ ] **Avoid `opt_getconstant_path`** — YJIT handles constant lookups well, but `_H = LiquidIL::StructuredHelpers` at the top of every proc could be passed as a parameter instead
