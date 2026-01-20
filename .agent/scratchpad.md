# Structured Compiler Session - 2026-01-20

## Current Issue

**RESOLVED**: Merged partial compilation feature with AND/OR chain fixes.

The working directory now contains 2047 lines with both features intact:
- Partial compilation (compile `{% render %}` and `{% include %}` to lambdas)
- Complex AND/OR chain handling (fixes for long boolean chains)

## Tasks

[x] Identify the regression (partial support removed)
[x] Restore partial compilation from ac1c50e
[x] Apply AND/OR chain fixes on top of partial code
[x] Verify tests pass: rake test (4344 matched), rake spec (4102 passed)
[ ] Commit the merged fix

## Previous Session Notes

### Fixed: Complex AND/OR chain handling in StructuredCompiler

The `if_with_many_conditions` test was failing due to three interrelated issues:

1. **Long literal OR chains** - `peek_if_statement?` couldn't find IS_TRUTHY at the end of long optimizer-generated `CONST_TRUE, JUMP +2` chains

2. **Statement boundary crossing** - `build_expression` consumed instructions from multiple statements, causing incorrect expression trees

3. **Operator precedence** - `a or b and c` was being parsed as `(a or b) and c` instead of `a or (b and c)`

### Solution Applied (but lost partial support)

Three fixes applied to `lib/liquid_il/structured_compiler.rb`:

1. **`peek_if_statement?`** - Updated to follow forward JUMP instructions to find IS_TRUTHY

2. **`build_expression`** - Added `seen_is_truthy` flag to recognize when IS_TRUTHY has been passed, so subsequent JUMP_IF_FALSE/TRUE is the condition branch, not short-circuit

3. **OR collection loop** - Added proper handling for nested AND expressions within OR chains

### Remaining Failures (pre-existing edge cases)

1. Dynamic range float bounds
2. Filter silent errors
3. Cycle 0 choices
4. For loop limit/offset validation
5. Forloop reset after nested loop
6. gsub escape sequences
7. Integer.size
