# Structured Compiler Session - 2026-01-20

## Current Epic: liquid-il-omv - YJIT-Friendly Structured Compiler

### Current State
- `rake test`: 4352 matched, 17 different (improved from 31)
- Session progress: Fixed 14 tests so far

### Session Fixes Applied
1. [x] Include `with` lookup order - lookup with_expr BEFORE keyword args modify scope (6 tests)
2. [x] Include `for` range iteration - ranges not iterated in include (1 test)
3. [x] Cycle with 0 choices - output empty instead of divide by 0 (1 test)
4. [x] Integer.size property - handle integer.size in __lookup__ (2 tests)
5. [x] Parentloop in include - check scope for forloop at depth 0 (1 test)
6. [x] Cycle state in include - share cycle state across include boundaries (2 tests)
7. [x] Tablerow parentloop - always use scope lookup for parent (1 test)

### 17 Remaining Failures (Categorized)

1. **Break/continue in capture** (3 tests) - Known limitation
   - `break_in_capture_in_loop`
   - `break_in_capture_not_in_loop`
   - `continue_in_capture_in_loop`

2. **Break/continue across include** (2 tests) - Known limitation
   - `break_outer_loop_pattern`
   - `break_in_nested_include_blocks`

3. **Tablerow break leaking** (1 test) - Known limitation
   - `tablerow_does_not_leak_interrupts`
   - Root cause: For loop body generation closes catch block before processing statements after nested tablerow
   - Fix requires refactoring for loop body parsing to include all statements until FOR_END

4. **Error formatting** (7 tests) - liquid-il-omv.11
   - `render_static_name_only` - error class name
   - `render_mutual_recursion` - error file location
   - `Liquid error in snippet` (x2)
   - `Range bound dynamic type check` (x2)
   - `for_loop_with_invalid_limit`
   - `for_loop_with_invalid_offset`
   - `includes_will_not_render_inside_nested_sibling_tags`

5. **Other** (3 tests)
   - `date_negative_timestamp` - timezone (external)
   - `replace_gsub_escape_sequences` - regex chars

### Previously Completed
[x] liquid-il-y68 - Handle long boolean chains (CLOSED)
[x] liquid-il-oua - Break/continue compilation (CLOSED)
[x] liquid-il-301 - Tablerow compilation (CLOSED)
[x] liquid-il-4k6 - Partials compile to lambda calls (CLOSED)
