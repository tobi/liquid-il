# Structured Compiler Session - 2026-01-20

## Current Epic: liquid-il-omv - YJIT-Friendly Structured Compiler

### Current State
- `rake test`: 4344 matched, 25 different (was 31)
- Fixed 6 `include with` tests by looking up with_expr BEFORE keyword args modify scope

### 25 Remaining Failures (Categorized)

1. **Cycle state in include** (2 tests) - liquid-il-omv.7
   - `cycle_shared_in_include` - cycle state not shared across include
   - `cycle_named_shared_in_include`

2. **Parentloop in include** (2 tests) - liquid-il-omv.6
   - `for_parentloop_available_in_include`
   - `forloop_parent_access_inside_tablerow`

3. **Break/continue in capture** (3 tests) - liquid-il-omv.8
   - `break_in_capture_in_loop`
   - `break_in_capture_not_in_loop`
   - `continue_in_capture_in_loop`

4. **Break/continue across include boundaries** (2 tests) - liquid-il-omv.8
   - `break_outer_loop_pattern` - flag variable pattern for outer loop break
   - `break_in_nested_include_blocks`

5. **Tablerow break leaking** (1 test) - liquid-il-omv.12
   - `tablerow_does_not_leak_interrupts`

6. **Error message formatting** (7 tests) - liquid-il-omv.11
   - `render_static_name_only` - error type mismatch
   - `render_mutual_recursion` - error location (a vs b)
   - `Liquid error in snippet` (x2 dups)
   - `Range bound dynamic type check rejects float` (x2 dups)
   - `for_loop_with_invalid_limit`
   - `for_loop_with_invalid_offset`
   - `includes_will_not_render_inside_nested_sibling_tags`

7. **Include `for` range iteration** (1 test)
   - `for_does_not_iterate_range` - `include 'foo' for (1..10)` shouldn't iterate

8. **Other edge cases** (7 tests)
   - `date_negative_timestamp` - timezone issue (not our bug)
   - `cycle_with_0_choices` - divide by 0
   - `forloop_is_reset_after_leaving_nested_loop`
   - `replace_gsub_escape_sequences` - regex special chars
   - `size_of_integer`

### Current Task: Commit include with fix

[x] Fix `generate_partial_call` to lookup with_expr BEFORE keyword args modify scope
[ ] Commit changes

### Previously Completed
[x] liquid-il-y68 - Handle long boolean chains (CLOSED)
[x] liquid-il-oua - Break/continue compilation (CLOSED)
[x] liquid-il-301 - Tablerow compilation (CLOSED)
[x] liquid-il-4k6 - Partials compile to lambda calls (CLOSED)
