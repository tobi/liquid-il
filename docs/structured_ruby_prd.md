# Structured Ruby Compiler PRD (YJIT/ZJIT-friendly)

## Problem
The current `lib/liquid_il/ruby_compiler.rb` emits a state machine. That shape prevents YJIT/ZJIT from optimizing hot paths. We need a compiler that emits **structured Ruby** (native `if/else`, `case`, and `each do`) while preserving Liquid semantics.

## Goals
- Generate structured Ruby that JITs well (no explicit program counter or opcode dispatch).
- Preserve Liquid semantics for:
  - truthiness, `blank`/`empty`, comparisons, `contains`
  - filters, drops, and `lookup` behavior
  - `for` loops including `limit`, `offset`, `offset:continue`, `reversed`, and `forloop`/`parentloop`
  - `for`-`else` behavior when the collection is empty
  - `break`/`continue` (Liquid interrupts)
  - `capture`, `assign`, `increment`/`decrement`, `cycle`
  - error recovery in non-strict mode
- Keep generated code readable and stable (predictable shapes for JIT).

## Non-goals
- Changing Liquid semantics.
- Rewriting the parser/IL.
- Adding new tags/filters.

## Current Structured Compiler (Critique)
`lib/liquid_il/structured_compiler.rb` is a good start but does **not** preserve Liquid semantics:
- **Loops:** uses `each_with_index` (block shape not ideal) and ignores Liquid’s iterator rules.
  - `limit`, `offset`, `offset:continue`, and `reversed` are not honored.
  - Strings are **not** iterated (Liquid treats non-empty strings as a single item).
  - `for-else` is ignored (Liquid executes `else` on empty collection).
- **Interrupts:** `break`/`continue` (`PUSH_INTERRUPT`) are unsupported.
- **Tablerow:** not supported.
- **Partials:** `render`/`include` are not supported.
- **Semantics divergence:** uses a simplified `__lookup__` and `__contains__` that differ from VM behavior.
- **Error handling:** no recovery behavior matching `VM` (e.g., invalid integer for limit/offset).
- **Expression reconstruction:** relies on IL scanning heuristics; brittle across new IL optimizations.

## Liquid Semantics We Must Preserve (from VM)
Key behaviors implemented in `lib/liquid_il/vm.rb`:
- **Iteration semantics** (`create_iterator`, `to_iterable`, `slice_collection`):
  - `nil`/`false` => empty collection
  - `String` => single item array (unless empty)
  - `Hash` => array of `[k, v]`
  - `RangeValue` => `to_a`
  - `limit`/`offset` validation (invalid integer => runtime error)
  - `offset:continue` uses stored offset keyed by loop name
  - `reversed` applies **after** slicing
- **forloop tracking:**
  - `forloop.index0` updated **after** each iteration so escaped values reflect final index
  - `forloop.parentloop` uses a stack
- **Truthiness:** only `nil`/`false` are falsy; `blank`/`empty` are special literals
- **Errors:** runtime errors are recovered (render_errors) and output continues

## Proposed Approach
### 1) Structured Code Model (IR)
Introduce a small structured IR in `Compiler::Structured`:
- `Sequence`, `If`, `IfElse`, `ForEach`, `Case`, `Write`, `Assign`, `Capture`, `Interrupt`, `Expr`
- Build from IL using a **control-flow-aware** pass (reuse basic-block CFG from `ruby_compiler.rb`).
- This avoids fragile IL scanning and makes new IL optimizations safe.

### 2) Loop Lowering (Liquid-accurate)
Create helper methods (shared with VM) for iteration:
- `__to_iterable__(value)`
- `__slice_collection__(items, from, to, is_string:)`
- `__for_iterator__(collection, loop_name, limit, offset, offset_continue, reversed)`

Then generate Ruby:
```ruby
__coll__ = __for_iterator__(collection_expr, loop_name, limit, offset, offset_continue, reversed)
if __coll__.any?
  __scope__.push_scope
  __forloop__ = LiquidIL::ForloopDrop.new(loop_name, __coll__.length, __parent__)
  __idx__ = 0
  __coll__.each do |__item__|
    __forloop__.index0 = __idx__
    __scope__.assign_local('forloop', __forloop__)
    __scope__.assign_local(item_var, __item__)
    # body
    __idx__ += 1
  end
  __scope__.pop_scope
else
  # for-else branch
end
```
Notes:
- `each` + manual index keeps a consistent block shape and avoids `each_with_index` allocations.
- Slicing happens *before* `reversed`, matching Liquid.
- Strings become `[string]` so they iterate once.

### 3) Interrupts (break/continue)
Emit Ruby `break`/`next` when encountering `PUSH_INTERRUPT` within loops. Use structured IR to scope correctly.
- For interrupts in partials, preserve propagation semantics (VM uses interrupt stack).

### 4) Semantics-accurate helpers
Share (or reuse) logic from VM for:
- `__lookup__` and `__contains__` (handling encoding mismatches and hash key rules)
- `__compare__` and `case_equal?`
- `__is_truthy__` including drops with `to_liquid_value`
- error recovery hooks (render_errors)

### 5) Codegen Guidelines (JIT-friendly)
- Prefer straight-line Ruby with minimal branching inside hot loops.
- Reuse helper lambdas/methods to keep callsites stable.
- Avoid building per-iteration Proc objects.
- Keep variable names stable per loop depth (`__idx_0__`, `__item_0__`).

## Test Plan
Add Minitest coverage for:
- Structured Ruby shape:
  - For loop uses `each do` and manual index
  - No `__pc__` in generated source
- Semantics parity (Structured vs VM):
  - `for` with `limit`, `offset`, `offset:continue`, `reversed`
  - `for-else` on empty collections
  - string iteration (single element)
  - `break` / `continue`
  - `forloop.parentloop` in nested loops
  - invalid `limit`/`offset` errors (render_errors behavior)

## Phased Implementation
1) **Phase 1**: Refactor StructuredCompiler to use `each do` + manual index (done), add tests.
2) **Phase 2**: Implement Liquid-accurate iteration helpers and for-else.
3) **Phase 3**: Add interrupts and loop-aware structured IR.
4) **Phase 4**: Expand semantics coverage (tablerow, include/render, error recovery).

## Risks
- Reconstructing structured control flow from IL can be brittle without CFG.
- Partial/include behavior interacts with `forloop.parentloop` and interrupts.
- Divergence from VM semantics if helpers are not shared.

## Open Questions
- Should structured compiler support partials in phase 2 or remain VM fallback?
- Should we share helpers with VM (module) or duplicate for performance?
- What is the priority ordering: correctness vs JIT-friendliness for edge cases?
