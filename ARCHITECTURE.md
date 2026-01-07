# LiquidIL Architecture

LiquidIL compiles Liquid templates to an intermediate language (IL) for execution on a stack-based virtual machine. This document describes the compilation pipeline and key data structures.

## Pipeline Overview

```
Source → TemplateLexer → Parser → IL → Linker → VM
              ↓              ↓
        ExpressionLexer  IL::Builder
```

## Stage 1: Template Lexing

**File:** `lib/liquid_il/lexer.rb` (TemplateLexer)

Splits source into three token types:
- `RAW` - Literal text between tags
- `TAG` - `{% ... %}` blocks
- `VAR` - `{{ ... }}` output expressions

Tracks whitespace trim markers (`-`) for proper output formatting.

```ruby
# Input: "Hello {{ name -}}!"
# Tokens: [[:RAW, "Hello "], [:VAR, "name", false, true], [:RAW, "!"]]
```

## Stage 2: Expression Lexing

**File:** `lib/liquid_il/lexer.rb` (ExpressionLexer)

Tokenizes tag/variable markup using byte lookup tables for O(1) punctuation dispatch.

Token types: `IDENTIFIER`, `NUMBER`, `STRING`, `DOT`, `DOTDOT`, `PIPE`, `COLON`, `COMMA`, comparison operators (`EQ`, `NE`, `LT`, `LE`, `GT`, `GE`), logic operators (`AND`, `OR`, `CONTAINS`), and literals (`NIL`, `TRUE`, `FALSE`, `EMPTY`, `BLANK`).

## Stage 3: Parsing & IL Emission

**File:** `lib/liquid_il/parser.rb`

Recursive descent parser that emits IL directly—no AST intermediate. Uses `IL::Builder` to construct instruction sequences with symbolic labels.

Key parsing methods:
- `parse_expression` → `parse_or_expression` → `parse_and_expression` → `parse_comparison_expression` → `parse_primary_expression`
- `parse_filters` - Filter chain processing
- `parse_if_tag`, `parse_for_tag`, `parse_case_tag`, etc. - Control flow tags

## Stage 4: IL Instruction Set

**File:** `lib/liquid_il/il.rb`

Instructions are simple arrays (`[:OPCODE, arg1, arg2]`) for minimal allocation.

### Complete Instruction Reference

| Instruction | Format | Description |
|-------------|--------|-------------|
| **Output** |||
| `WRITE_RAW` | `[:WRITE_RAW, string]` | Write literal string to output |
| `WRITE_VALUE` | `[:WRITE_VALUE]` | Pop stack, convert to string, write to output |
| **Constants** |||
| `CONST_NIL` | `[:CONST_NIL]` | Push nil |
| `CONST_TRUE` | `[:CONST_TRUE]` | Push true |
| `CONST_FALSE` | `[:CONST_FALSE]` | Push false |
| `CONST_INT` | `[:CONST_INT, value]` | Push integer |
| `CONST_FLOAT` | `[:CONST_FLOAT, value]` | Push float |
| `CONST_STRING` | `[:CONST_STRING, value]` | Push string |
| `CONST_RANGE` | `[:CONST_RANGE, start, end]` | Push range literal |
| `CONST_EMPTY` | `[:CONST_EMPTY]` | Push empty literal (for `== empty`) |
| `CONST_BLANK` | `[:CONST_BLANK]` | Push blank literal (for `== blank`) |
| **Variable Access** |||
| `FIND_VAR` | `[:FIND_VAR, name]` | Look up variable by name, push to stack |
| `FIND_VAR_DYNAMIC` | `[:FIND_VAR_DYNAMIC]` | Pop name from stack, look up, push result |
| `LOOKUP_KEY` | `[:LOOKUP_KEY]` | Pop key, pop object, push object[key] |
| `LOOKUP_CONST_KEY` | `[:LOOKUP_CONST_KEY, name]` | Pop object, push object[name] |
| `LOOKUP_COMMAND` | `[:LOOKUP_COMMAND, name]` | Optimized lookup for size/first/last |
| **Control Flow** |||
| `LABEL` | `[:LABEL, id]` | Define jump target (removed by linker) |
| `JUMP` | `[:JUMP, target]` | Unconditional jump |
| `JUMP_IF_FALSE` | `[:JUMP_IF_FALSE, target]` | Pop, jump if falsy |
| `JUMP_IF_TRUE` | `[:JUMP_IF_TRUE, target]` | Pop, jump if truthy |
| `JUMP_IF_EMPTY` | `[:JUMP_IF_EMPTY, target]` | Peek, jump if empty (for else in for) |
| `JUMP_IF_INTERRUPT` | `[:JUMP_IF_INTERRUPT, target]` | Jump if break/continue pending |
| `HALT` | `[:HALT]` | End execution |
| **Comparison** |||
| `COMPARE` | `[:COMPARE, op]` | Pop b, a, push a op b (eq/ne/lt/le/gt/ge) |
| `CASE_COMPARE` | `[:CASE_COMPARE]` | Stricter comparison for case/when |
| `CONTAINS` | `[:CONTAINS]` | Pop b, a, push a.include?(b) |
| `BOOL_NOT` | `[:BOOL_NOT]` | Pop, push logical negation |
| `IS_TRUTHY` | `[:IS_TRUTHY]` | Pop, push boolean (only nil/false are falsy) |
| **Scope & Assignment** |||
| `PUSH_SCOPE` | `[:PUSH_SCOPE]` | Push new variable scope |
| `POP_SCOPE` | `[:POP_SCOPE]` | Pop variable scope |
| `ASSIGN` | `[:ASSIGN, name]` | Pop value, assign to root scope |
| `ASSIGN_LOCAL` | `[:ASSIGN_LOCAL, name]` | Pop value, assign to current scope |
| **Loops (for)** |||
| `FOR_INIT` | `[:FOR_INIT, var, loop_name, limit?, offset?, continue?, reversed?]` | Initialize for loop |
| `FOR_NEXT` | `[:FOR_NEXT, continue_label, break_label]` | Advance iterator or exit |
| `FOR_END` | `[:FOR_END]` | Clean up for loop |
| `PUSH_FORLOOP` | `[:PUSH_FORLOOP]` | Push forloop to stack (for parentloop) |
| `POP_FORLOOP` | `[:POP_FORLOOP]` | Pop forloop from stack |
| **Loops (tablerow)** |||
| `TABLEROW_INIT` | `[:TABLEROW_INIT, var, loop_name, limit?, offset?, cols]` | Initialize tablerow |
| `TABLEROW_NEXT` | `[:TABLEROW_NEXT, continue_label, break_label]` | Advance with `<tr>`/`<td>` output |
| `TABLEROW_END` | `[:TABLEROW_END]` | Clean up tablerow |
| **Interrupts** |||
| `PUSH_INTERRUPT` | `[:PUSH_INTERRUPT, type]` | Signal break or continue |
| `POP_INTERRUPT` | `[:POP_INTERRUPT]` | Clear interrupt |
| **Filters** |||
| `CALL_FILTER` | `[:CALL_FILTER, name, argc]` | Pop args and value, push filter result |
| **Capture** |||
| `PUSH_CAPTURE` | `[:PUSH_CAPTURE]` | Start capturing output |
| `POP_CAPTURE` | `[:POP_CAPTURE]` | Stop capture, push captured string |
| **Partials** |||
| `RENDER_PARTIAL` | `[:RENDER_PARTIAL, name, args]` | Render with isolated scope |
| `INCLUDE_PARTIAL` | `[:INCLUDE_PARTIAL, name, args]` | Include with shared scope |
| **Special Tags** |||
| `INCREMENT` | `[:INCREMENT, name]` | Increment counter, push old value |
| `DECREMENT` | `[:DECREMENT, name]` | Decrement counter, push new value |
| `CYCLE_STEP` | `[:CYCLE_STEP, identity, values]` | Cycle through values |
| `CYCLE_STEP_VAR` | `[:CYCLE_STEP_VAR, var, values]` | Cycle with variable group |
| `IFCHANGED_CHECK` | `[:IFCHANGED_CHECK, tag_id]` | Output if value changed |
| **Stack** |||
| `DUP` | `[:DUP]` | Duplicate top of stack |
| `POP` | `[:POP]` | Discard top of stack |
| `BUILD_HASH` | `[:BUILD_HASH, count]` | Pop count*2 items, push hash |
| `STORE_TEMP` | `[:STORE_TEMP, index]` | Store top in temp slot |
| `LOAD_TEMP` | `[:LOAD_TEMP, index]` | Load from temp slot |
| `NEW_RANGE` | `[:NEW_RANGE]` | Pop end, start, push range |
| `NOOP` | `[:NOOP]` | No operation |

### Example IL

Template: `{% if user %}Hello {{ user.name }}{% endif %}`

```
FIND_VAR "user"
IS_TRUTHY
JUMP_IF_FALSE L1
WRITE_RAW "Hello "
FIND_VAR "user"
LOOKUP_CONST_KEY "name"
WRITE_VALUE
LABEL L1
HALT
```

## Stage 5: Linking

**File:** `lib/liquid_il/il.rb` (IL.link)

Two-pass process:
1. Collect label positions (symbol → instruction index)
2. Resolve jump targets (replace symbolic labels with indices)

## Stage 6: VM Execution

**File:** `lib/liquid_il/vm.rb`

Stack-based virtual machine with:
- **Value stack** - Expression evaluation
- **Program counter** - Current instruction
- **Iterator stack** - Nested for loop state
- **Interrupt stack** - Break/continue propagation

### Core Abstractions

| Method | Purpose |
|--------|---------|
| `to_output(value)` | Convert any value to output string (handles `to_liquid`) |
| `to_iterable(value)` | Convert value to array for for loops |
| `is_truthy(value)` | Liquid semantics: only `nil` and `false` are falsy |
| `is_empty(value)` | For `== empty` comparisons |
| `is_blank(value)` | For `== blank` comparisons |
| `lookup_property(obj, key)` | Property access with Drop protocol support |

## Supporting Components

### Context (`lib/liquid_il/context.rb`)
Manages variable scopes, forloop state, interrupts, captures, and render depth tracking.

### Filters (`lib/liquid_il/filters.rb`)
Standard Liquid filter implementations (50+ filters including string, array, math, date).

### Drops (`lib/liquid_il/drops.rb`)
Drop protocol support: `ForloopDrop`, `TablerowloopDrop` for loop metadata.

### Context Types (`lib/liquid_il/context.rb`)
- `RangeValue` - Lazy range representation
- `EmptyLiteral` - The `empty` keyword
- `BlankLiteral` - The `blank` keyword

### Utils (`lib/liquid_il/utils.rb`)
Shared utilities for value coercion and output formatting.

### Compiler (`lib/liquid_il/compiler.rb`)
Wraps parser with optional optimization passes:
- Merge consecutive `WRITE_RAW` instructions
- Remove unreachable code after unconditional jumps

### Pretty Printer (`lib/liquid_il/pretty_printer.rb`)
Human-readable IL output for debugging.

## Data Flow Example

```ruby
# 1. Parse
template = LiquidIL::Template.parse("Hello {{ name | upcase }}")

# 2. Compile (returns linked IL)
# Instructions:
#   [:WRITE_RAW, "Hello "]
#   [:FIND_VAR, "name"]
#   [:CALL_FILTER, "upcase", 0]
#   [:WRITE_VALUE]
#   [:HALT]

# 3. Execute
output = template.render("name" => "world")
# => "Hello WORLD"
```

## Performance Design

1. **Zero-allocation hot paths** - StringScanner `skip` instead of `scan`, byte lookup tables, deferred string extraction
2. **Compile-time decisions** - Filter aliases resolved during parsing, constant folding in optimizer
3. **Simple instruction encoding** - Arrays instead of objects for minimal GC pressure
4. **Direct IL emission** - No intermediate AST allocation
