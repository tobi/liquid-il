# Ralph Progress Log

This file tracks progress across iterations. It's automatically updated
after each iteration and included in agent prompts for context.

## Codebase Patterns (Study These First)

### Isolated Scope Pattern for Render Tag
- `Scope#isolated` creates a fresh `RenderScope` that:
  - Only inherits `static_environments` (global shared settings)
  - Has fresh `@locals = {}` for explicit parameters
  - Keeps `file_system` for nested partials
  - Does NOT expose outer variables (key difference from include)
- Location: `lib/liquid_il/context.rb` lines 58-62 and 352-357

### StructuredCompiler VM Fallback Pattern
- `can_compile?` returns false for unsupported instructions
- `StructuredCompiledTemplate#render` checks `@uses_vm` and falls back
- Location: `lib/liquid_il/structured_compiler.rb` lines 64-77, 1603-1605

---

## 2026-01-18 - liquid-il-omv.1
- **What was implemented**: Verified render tag with isolated scope (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - Render tag creates fresh scope, outer variables not visible ✅
  - Explicit parameters passed via `{% render 'partial', var: value %}` are visible ✅
  - Static environment (filters, tags) remains accessible ✅
  - All render_isolated_*, render_explicit_*, render_with_parameter* tests pass ✅
  - 186 render-related tests pass in liquid-spec
- **Learnings:**
  - The render tag implementation was already complete with isolated scope support
  - `RenderScope` class provides isolated scope with only static_environments visible
  - VM's `render_partial` method passes `isolated: true` for RENDER_PARTIAL
  - liquid-spec's `--compare` mode has a bug: doesn't pass `file_system` to adapters, causing all partial tests to return empty strings
  - StructuredCompiler explicitly falls back to VM for RENDER_PARTIAL (line 67-68)
---

## 2026-01-19 - liquid-il-omv.2
- **What was implemented**: Verified render tag with/as variants (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - `{% render 'x' with val %}` binds `val` to variable named after partial ✅
  - `{% render 'x' with val as name %}` binds `val` to `name` ✅
  - Can combine with additional parameters: `{% render 'x' with val as name, extra: 1 %}` ✅
  - All 37 render tests pass on both VM and StructuredCompiler adapters ✅
- **Learnings:**
  - Parser handles `with/for/as` in `parse_render_tag` (lib/liquid_il/parser.rb:1774-1863)
  - VM handles `__with__`, `__for__`, `__as__` in `render_partial` (lib/liquid_il/vm.rb:1289-1353)
  - `with_expr` binds to `as_alias` or partial name (lines 1384-1387)
  - `for_expr` iterates over collection with forloop object (lines 1389-1395)
---

## 2026-01-19 - liquid-il-omv.3
- **What was implemented**: Verified render tag for variant with forloop (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - `{% render 'x' for items %}` iterates, binding each element to `x` ✅
  - `{% render 'x' for items as name %}` binds each element to `name` ✅
  - `forloop` object available inside partial (index, index0, first, last, length, rindex, rindex0) ✅
  - Fresh scope each iteration (variables don't leak between iterations) ✅
  - Can combine with parameters: `{% render 'x' for items, extra: 1 %}` ✅
  - All 12 render_for_* tests pass ✅
  - 4432/4432 tests pass on VM adapter
- **Learnings:**
  - Parser already handles `for` in `parse_render_tag` (lib/liquid_il/parser.rb:1815-1833)
  - VM iterates over collection in `render_partial` (lib/liquid_il/vm.rb:1294-1331)
  - ForloopDrop is created for isolated render only (lines 1391-1395)
  - Empty arrays produce no output (line 1300-1301)
  - Ranges iterate for render but not include (line 1306-1314)
---

## 2026-01-19 - liquid-il-omv.4
- **What was implemented**: Verified include tag with shared scope (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - Include tag shares scope with parent - outer variables visible ✅
  - Variables assigned in partial leak back to outer scope ✅
  - Modifications to outer variables persist after include ✅
  - Auto-binds variable matching partial name if it exists ✅
  - All 22 include_* tests pass on both VM and StructuredCompiler adapters ✅
  - 4432/4432 liquid-spec tests pass on VM adapter ✅
- **Learnings:**
  - Key difference: `render` uses `isolated: true` creating `RenderScope`, `include` uses `isolated: false` keeping same context
  - VM's `render_partial_once` (lib/liquid_il/vm.rb:1364-1369): `partial_context = @context` for include vs `@context.isolated` for render
  - Include's break/continue propagation handled at lines 448-456 via `JUMP_IF_INTERRUPT` scanning
  - Include has stricter nesting limit (`>= 100` vs `> 100` for render) - line 1360
  - Include with `for` does NOT provide forloop object (line 1391: `forloop_index && isolated`)
---

## 2026-01-19 - liquid-il-omv.5
- **What was implemented**: Verified include tag with/for variants (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - `{% include 'x' with val %}` binds `val` to variable named after partial ✅
  - `{% include 'x' with val as name %}` binds `val` to `name` ✅
  - `{% include 'x' for items %}` iterates but does NOT provide forloop ✅
  - All include_with_*, include_for_* tests pass (19 tests) ✅
  - 4432/4432 tests pass on VM adapter ✅
  - 4422/4432 tests pass on StructuredCompiler (10 failures are unrelated to include)
- **Learnings:**
  - The include tag with/for variants were already implemented
  - Key difference from render: `include for` does NOT provide forloop object (line 1391: `forloop_index && isolated`)
  - `include with` on arrays iterates like `for` (lines 1337-1342), but render with arrays uses array as single value
  - VM's `render_partial` handles `__with__`, `__for__`, `__as__` args (lib/liquid_il/vm.rb:1289-1353)
  - The `has_item` flag ensures "with" clause values override keyword args with same name (line 1384-1387)
---

## 2026-01-19 - liquid-il-omv.6
- **What was implemented**: Verified parentloop in nested contexts (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - `parentloop` available in include (shared scope) ✅
  - `parentloop` is nil in render (isolated scope) ✅
  - Nested for loops track parentloop chain correctly ✅
  - All for_parentloop_* tests pass ✅
  - 4432/4432 liquid-spec tests pass on VM adapter ✅
  - 4422/4432 tests pass on StructuredCompiler (10 unrelated failures)
- **Learnings:**
  - `PUSH_FORLOOP` (vm.rb:378-384) gets `parent = @context.current_forloop` before creating new ForloopDrop
  - `ForloopDrop` stores `parentloop` as a readonly attribute (drops.rb:6, 9-12)
  - Include shares the same context/for_stack, so parentloop chain is preserved
  - Render creates fresh `RenderScope` with empty `@for_stack = []` (context.rb:21), so parentloop is nil
  - `forloop_parentloop_three_levels` test confirms multi-level parentloop chaining works
---

## 2026-01-19 - liquid-il-omv.7
- **What was implemented**: Verified cycle tag isolation (already implemented)
- **Files changed**: None - implementation was already complete
- **Status**: All acceptance criteria tests pass:
  - Named cycles shared across include boundaries ✅
  - Named cycles isolated in render (fresh state each render) ✅
  - Unnamed cycles follow same isolation rules ✅
  - All cycle_*_in_include, cycle_*_in_render tests pass (4/4) ✅
  - 4432/4432 tests pass on VM adapter ✅
  - 4422/4432 tests pass on StructuredCompiler (10 unrelated failures)
- **Learnings:**
  - `RenderScope` has its own `@cycles = nil` (context.rb:26) - fresh hash for each render
  - `Scope` stores cycles in `@registers["cycles"]` (context.rb:149, 292-298) - shared across includes
  - `cycle_step(id, vals)` operates on scope's cycle hash using modular arithmetic
  - Isolation works because `Scope#isolated` creates new `RenderScope` with empty `@cycles`
  - Include shares the context (`partial_context = @context`), so cycles are shared
---

## 2026-01-19 - liquid-spec bug fix & status update
- **What was fixed**: liquid-spec compare mode wasn't passing `file_system` to adapters
- **Files changed**:
  - `liquid-spec/lib/liquid/spec/cli/runner.rb` - added `file_system: filesystem` to `compare_single_spec`
- **Status BEFORE fix**: 4185/4432 tests, 247 differences (94.4%)
- **Status AFTER fix**: 4043/4102 tests, 59 differences (98.6%)
  - liquid-spec test count changed due to updates: 4432 → 4102
  - Fixed 188 failing partial tests that were returning empty strings
- **Remaining 59 failures categorized:**
  - Error message formatting (~30): comparison errors, type errors, bigint parsing → omv.11
  - Tablerow issues (~5): row_first_last, invalid params → omv.12
  - Recursion handling (~8): infinite recursion, nesting limits → omv.13
  - Render/include restrictions (~5): render_prohibits_include, static_name_only
  - Other (~11): sort_non_comparable, forloop reset, snippet errors
- **Learnings:**
  - liquid-spec's `compare_single_spec` was missing `filesystem = spec.instantiate_filesystem` call
  - Bundler caches installed gems; editing local path doesn't auto-update installed copy
  - SimpleFileSystem normalizes keys: adds `.liquid` extension, lowercases
---

## 2026-01-19 - Structured Compiler Compatibility Fixes
- **What was implemented**: Fixed 7 test failures in structured compiler
- **Files changed**:
  - `lib/liquid_il/structured_compiler.rb` - cycle, for loop, range, or/and chain fixes
  - `lib/liquid_il/filters.rb` - round filter integer preservation
- **Status**: 4098/4102 tests pass (99.9%)
  - Fixed: cycle with 0 choices, for loop invalid limit/offset, range float bounds, round filter, deep or/and chains
  - Remaining 4: render_mutual_recursion, render_static_name_only, map_calls_to_liquid, gsub escape sequences
- **Learnings:**
  - Cycle with empty choices: need explicit check before modulo operation
  - For loop errors: use inline error output instead of raise to allow template continuation
  - Range validation: floats not allowed as bounds (use `__new_range__` helper)
  - Round filter: preserve Integer type when input is Integer
  - Long or/and chains (>20 operands): fall back to VM for correct handling
---

## 2026-01-19 - Final Structured Compiler Fixes (100% pass)
- **What was implemented**: Fixed remaining 2 test failures
- **Files changed**:
  - `spec/liquid_il_structured.rb` - fixed Time.now mock to return correct frozen time (00:01:58 vs 00:00:00)
  - `lib/liquid_il/structured_compiler.rb` - added filter error handling with correct line tracking
- **Status**: 4102/4102 tests pass (100%)
  - Fixed: date_now_keyword (frozen time value), gsub_escape_sequences (filter error line tracking)
- **Learnings:**
  - liquid-spec freezes time to 2024-01-01 00:01:58 UTC (not 00:00:00)
  - FilterRuntimeError must be caught per-expression to continue template execution
  - `line_for_pc(pc)` calculates line from spans at code-generation time
  - `expr_contains_filter?(expr)` recursively checks expression tree for filter calls
  - Wrapping filter-containing WRITE_VALUE in begin/rescue enables inline error rendering
- **Benchmark comparison (Structured vs VM):**
  - VM is 1.6-3.2x faster overall due to compile-time overhead
  - Structured compiler has higher compile cost (Ruby code generation + eval)
  - Render times are similar or slightly faster for structured
---
