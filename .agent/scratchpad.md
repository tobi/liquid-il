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
   - Known limitation: break inside capture doesn't work correctly

3. [ ] **liquid-il-y68** (P3) - Handle long boolean chains
   - Currently has 50-iteration safety limit in peek_if_statement
   - May need to raise/remove limit or convert to array check

### Completed
[x] liquid-il-4k6 - Partials compile to lambda calls (closed)
[x] liquid-il-oua - Break/continue compilation (closed)
[x] liquid-il-301 - Tablerow compilation (mostly working - ready to close)

### Current State
- `rake matrix`: 4348 matched, 21 different
- `liquid-spec structured`: 4085 passed, 17 failed
- can_compile? no longer blocks on: PUSH_INTERRUPT, TABLEROW_INIT/NEXT/END

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
- Proper offset/limit validation (skip when collection is nil)
- cols parameter handling including :dynamic and :explicit_nil

### Remaining Issues (17 failures)
1. break_outer_loop_pattern - complex nested loop break
2. break_in_capture_in_loop - throw/catch unwinds capture stack incorrectly
3. Some boolean operator edge cases
4. Range bound type checks with floats
5. Some tablerow edge cases with strict mode
