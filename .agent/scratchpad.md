# Structured Compiler Session - 2026-01-20

## Session Summary

This session investigated implementing break/continue support for the structured compiler (issue liquid-il-oua).

## Investigation Results

### Attempted Implementation

Implemented break/continue using Ruby's native `break` and `next` keywords:
1. `PUSH_INTERRUPT :break` → Ruby's `break`
2. `PUSH_INTERRUPT :continue` → Ruby's `next`
3. Break/continue outside loops → `throw :__liquid_interrupt__` with catch wrapper

### Why It Was Reverted

The implementation introduced 19 new test failures due to complex partial semantics:

1. **break_contained_in_render** - Break in render partial should NOT propagate to outer loop
2. **break_propagates_through_include** - Break in include partial SHOULD propagate to outer loop
3. **continue_propagates_through_include** - Same pattern for continue

The challenge is that `render` and `include` have different interrupt semantics:
- `{% render %}` - Isolated scope, break/continue should be contained within partial
- `{% include %}` - Shared scope, break/continue should propagate to caller's loop

### Options for Proper Implementation

1. **Scope interrupt flags (like VM)**: Use `__scope__.push_interrupt(:break)` and check flag after each statement. Matches VM semantics exactly but loses Ruby's efficient native control flow.

2. **Hybrid approach**:
   - Simple loops without partials: Ruby's `break`/`next` (fast path)
   - Loops with include partials: Use scope interrupt flags
   - Render partials: Wrap calls in `catch(:__liquid_interrupt__)`

3. **Compile-time detection**: Detect if a template uses partials that could propagate interrupts and choose the appropriate strategy.

### Recommendation

The proper implementation requires careful handling of partial boundary semantics. This should be a dedicated task with thorough test coverage. For now, break/continue continues to trigger VM fallback.

## Test Status

- `rake spec`: 4102 passed
- `rake test`: 4345 matched, 24 different (pre-existing edge cases)

## Epic Progress: liquid-il-co1 (Eliminate VM fallback)

- [x] liquid-il-4k6: Compile partials to lambda calls
- [x] liquid-il-y68: Handle long boolean chains
- [ ] liquid-il-301: Compile tablerow to native Ruby
- [ ] liquid-il-oua: Compile break/continue (complex - needs careful partial handling)

## Known Remaining Failures (24 pre-existing edge cases)

1. Dynamic range float bounds
2. Filter silent errors
3. Cycle 0 choices
4. For loop limit/offset validation
5. Forloop reset after nested loop
6. gsub escape sequences
7. Integer.size
