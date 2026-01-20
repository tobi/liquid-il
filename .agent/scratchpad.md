# Structured Compiler Session - 2026-01-20

## Current Epic: liquid-il-co1 - Eliminate VM fallback in structured compiler

### Remaining Tasks (Priority Order)

1. [x] **liquid-il-oua** (P2) - Compile break/continue in structured compiler ✓
   - Implemented using throw/catch pattern for break, Ruby's next for continue
   - Fixed body indent and JUMP_IF_INTERRUPT handling

2. [x] **liquid-il-301** (P2) - Compile tablerow to native Ruby ✓
   - Implemented similar structure to for loops with HTML table output
   - Handles cols, limit, offset parameters
   - Fixed expression parsing for ranges and dotted access
   - **Fixed**: Bracket lookup (collections["key"]) in build_single_value_expression

3. [ ] **liquid-il-y68** (P3) - Handle long boolean chains
   - Currently has 50-iteration safety limit in peek_if_statement
   - May need to raise/remove limit or convert to array check

### Completed
[x] liquid-il-4k6 - Partials compile to lambda calls (closed)
[x] liquid-il-oua - Break/continue compilation (closed)
[x] liquid-il-301 - Tablerow compilation (closed)

### Current State (after this session)
- `rake test`: 4338 matched, 31 different (improved from 33)
- `rake spec`: 4102 passed
- can_compile? no longer blocks on: PUSH_INTERRUPT, TABLEROW_INIT/NEXT/END

### Known Limitations
1. **break/continue in partials** - When a partial contains break/continue and is included inside a for loop, the throw/catch pattern doesn't propagate correctly across lambda boundaries. Fallback detection added for this case.
2. **break inside capture** - throw/catch unwinds capture stack incorrectly
3. **break_outer_loop_pattern** - Complex nested loop break with flag variable

### Implementation Notes

#### Break/Continue (Completed)
Used throw/catch pattern for break to avoid LocalJumpError in nested blocks.
Ruby's native `next` works for continue inside each blocks.

Key changes:
- Wrap for loops with `catch(:loop_break_N)` where N is loop depth
- Generate `throw(:loop_break_N)` for break
- Generate `next` for continue
- Fixed body indent from +2 to +3 for catch wrapper
- Removed JUMP_IF_INTERRUPT from body-terminating list
- Added `partial_uses_interrupts?` check to fall back when include contains break/continue

#### Tablerow (Completed)
Tablerow generates HTML table structure:
- `<tr class="rowN">` at start of each row
- `<td class="colN">content</td>` for each cell
- `</tr>` at end of each row (including on break)

Key implementation:
- Added `peek_tablerow?` method to detect tablerow loops
- Extended `build_single_value_expression` to handle:
  - Ranges (CONST_INT + CONST_INT/FLOAT + NEW_RANGE)
  - Property access (FIND_VAR + LOOKUP_CONST_KEY chains)
  - **Bracket lookup** (FIND_VAR + CONST_STRING + LOOKUP_KEY) for collections["key"]
- Proper offset/limit validation (skip when collection is nil)
- cols parameter handling including :dynamic and :explicit_nil

### Session Changes
- Fixed bracket lookup in tablerow collection expressions
- Test improvement: 33 different -> 31 different
