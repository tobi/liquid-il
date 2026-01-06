# LiquidIL Architecture

LiquidIL compiles Liquid templates to an intermediate language (IL) for high-performance execution. This document describes the compilation pipeline and key data structures.

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
- `parse_if_tag`, `parse_for_tag`, etc. - Control flow tags

## Stage 4: IL Instruction Set

**File:** `lib/liquid_il/il.rb`

Instructions are simple arrays (`[:OPCODE, arg1, arg2]`) for minimal allocation.

### Instruction Categories

| Category | Instructions | Purpose |
|----------|-------------|---------|
| **Output** | `WRITE_RAW`, `WRITE_VALUE` | Emit to output buffer |
| **Constants** | `CONST_NIL`, `CONST_TRUE`, `CONST_FALSE`, `CONST_INT`, `CONST_FLOAT`, `CONST_STRING`, `CONST_RANGE`, `CONST_EMPTY`, `CONST_BLANK` | Push literals to stack |
| **Lookups** | `FIND_VAR`, `FIND_VAR_DYNAMIC`, `LOOKUP_KEY`, `LOOKUP_CONST_KEY`, `LOOKUP_COMMAND` | Variable and property access |
| **Control Flow** | `LABEL`, `JUMP`, `JUMP_IF_FALSE`, `JUMP_IF_TRUE`, `JUMP_IF_EMPTY`, `JUMP_IF_INTERRUPT`, `HALT` | Branching and jumps |
| **Comparison** | `COMPARE`, `CONTAINS`, `BOOL_NOT`, `IS_TRUTHY` | Boolean operations |
| **Scope** | `PUSH_SCOPE`, `POP_SCOPE`, `ASSIGN` | Variable assignment |
| **Loops** | `FOR_INIT`, `FOR_NEXT`, `FOR_END`, `PUSH_FORLOOP`, `POP_FORLOOP` | Iteration |
| **Interrupts** | `PUSH_INTERRUPT`, `POP_INTERRUPT` | Break/continue handling |
| **Filters** | `CALL_FILTER` | Apply filter functions |
| **Capture** | `PUSH_CAPTURE`, `POP_CAPTURE` | String capture blocks |
| **Partials** | `RENDER_PARTIAL`, `INCLUDE_PARTIAL` | Template inclusion |
| **Stack** | `DUP`, `POP`, `STORE_TEMP`, `LOAD_TEMP` | Stack manipulation |

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
Manages variable scopes, forloop state, interrupts, and captures.

### Filters (`lib/liquid_il/filters.rb`)
Standard Liquid filter implementations.

### Drops (`lib/liquid_il/drops.rb`)
Drop protocol support: `ForloopDrop`, `RangeValue`, `EmptyLiteral`, `BlankLiteral`.

### Utils (`lib/liquid_il/utils.rb`)
Shared utilities for value coercion and output formatting.

### Compiler (`lib/liquid_il/compiler.rb`)
Wraps parser with optional optimization passes:
- Merge consecutive `WRITE_RAW` instructions
- Remove unreachable code after unconditional jumps

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
