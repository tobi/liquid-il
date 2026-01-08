# LiquidIL Intermediate Language

LiquidIL compiles Liquid templates to a stack-based intermediate language (IL) before execution. The IL is defined in [`lib/liquid_il/il.rb`](../../../lib/liquid_il/il.rb).

## Inspecting IL

Use the `liquidil` CLI to inspect IL for templates:

```bash
# Parse a template and show IL
./bin/liquidil parse "{{ name | upcase }}"

# Also show generated Ruby code
./bin/liquidil parse "{% for i in (1..3) %}{{ i }}{% endfor %}" --print-ruby

# Inspect specs from benchmarks
./bin/liquidil inspect bench_ecommerce -s benchmarks/partials.yml --print-il

# Inspect with Ruby code generation
./bin/liquidil inspect bench_product_listing -s benchmarks/suite.yml --print-ruby

# Disable optimizations to see raw IL
./bin/liquidil parse "{{ 1 | plus: 2 }}" --no-optimize
```

## IL Instruction Reference

All instructions are arrays: `[:OPCODE, arg1, arg2, ...]`

### Output

| Instruction | Format | Description |
|-------------|--------|-------------|
| `WRITE_RAW` | `[:WRITE_RAW, string]` | Output literal string |
| `WRITE_VALUE` | `[:WRITE_VALUE]` | Pop stack, output as string |

### Constants (push to stack)

| Instruction | Format | Description |
|-------------|--------|-------------|
| `CONST_NIL` | `[:CONST_NIL]` | Push `nil` |
| `CONST_TRUE` | `[:CONST_TRUE]` | Push `true` |
| `CONST_FALSE` | `[:CONST_FALSE]` | Push `false` |
| `CONST_INT` | `[:CONST_INT, value]` | Push integer |
| `CONST_FLOAT` | `[:CONST_FLOAT, value]` | Push float |
| `CONST_STRING` | `[:CONST_STRING, value]` | Push string |
| `CONST_RANGE` | `[:CONST_RANGE, start, end]` | Push range literal |
| `CONST_EMPTY` | `[:CONST_EMPTY]` | Push `empty` literal |
| `CONST_BLANK` | `[:CONST_BLANK]` | Push `blank` literal |

### Variable Access

| Instruction | Format | Description |
|-------------|--------|-------------|
| `FIND_VAR` | `[:FIND_VAR, name]` | Look up variable, push to stack |
| `FIND_VAR_PATH` | `[:FIND_VAR_PATH, name, [path]]` | Look up variable with path |
| `FIND_VAR_DYNAMIC` | `[:FIND_VAR_DYNAMIC]` | Pop name from stack, look up |
| `LOOKUP_KEY` | `[:LOOKUP_KEY]` | Pop key, pop object, push `object[key]` |
| `LOOKUP_CONST_KEY` | `[:LOOKUP_CONST_KEY, name]` | Pop object, push `object[name]` |
| `LOOKUP_CONST_PATH` | `[:LOOKUP_CONST_PATH, [names]]` | Pop object, traverse path |
| `LOOKUP_COMMAND` | `[:LOOKUP_COMMAND, name]` | Optimized for `size`/`first`/`last` |

### Control Flow

| Instruction | Format | Description |
|-------------|--------|-------------|
| `LABEL` | `[:LABEL, id]` | Jump target marker |
| `JUMP` | `[:JUMP, label_id]` | Unconditional jump |
| `JUMP_IF_FALSE` | `[:JUMP_IF_FALSE, label_id]` | Jump if stack top is falsy |
| `JUMP_IF_TRUE` | `[:JUMP_IF_TRUE, label_id]` | Jump if stack top is truthy |
| `JUMP_IF_EMPTY` | `[:JUMP_IF_EMPTY, label_id]` | Jump if stack top is empty |
| `JUMP_IF_INTERRUPT` | `[:JUMP_IF_INTERRUPT, label_id]` | Jump if break/continue pending |
| `HALT` | `[:HALT]` | End execution |

### Comparison & Logic

| Instruction | Format | Description |
|-------------|--------|-------------|
| `COMPARE` | `[:COMPARE, op]` | Pop two values, push comparison result. `op`: `:eq`/`:ne`/`:lt`/`:le`/`:gt`/`:ge` |
| `CASE_COMPARE` | `[:CASE_COMPARE]` | Case/when comparison (stricter blank/empty) |
| `CONTAINS` | `[:CONTAINS]` | Pop needle, pop haystack, push boolean |
| `BOOL_NOT` | `[:BOOL_NOT]` | Logical negation |
| `IS_TRUTHY` | `[:IS_TRUTHY]` | Convert to boolean |

### Scope & Assignment

| Instruction | Format | Description |
|-------------|--------|-------------|
| `PUSH_SCOPE` | `[:PUSH_SCOPE]` | Enter new variable scope |
| `POP_SCOPE` | `[:POP_SCOPE]` | Exit variable scope |
| `ASSIGN` | `[:ASSIGN, name]` | Pop value, assign to variable |
| `ASSIGN_LOCAL` | `[:ASSIGN_LOCAL, name]` | Assign to current scope only (loop vars) |

### Filters

| Instruction | Format | Description |
|-------------|--------|-------------|
| `CALL_FILTER` | `[:CALL_FILTER, name, argc]` | Pop `argc` args, pop input, push result |

### Loops

| Instruction | Format | Description |
|-------------|--------|-------------|
| `FOR_INIT` | `[:FOR_INIT, var, loop_name, has_limit, has_offset, offset_continue, reversed]` | Initialize for loop |
| `FOR_NEXT` | `[:FOR_NEXT, continue_label, break_label]` | Advance iterator or jump to break |
| `FOR_END` | `[:FOR_END]` | Clean up for loop |
| `PUSH_FORLOOP` | `[:PUSH_FORLOOP]` | Create forloop drop |
| `POP_FORLOOP` | `[:POP_FORLOOP]` | Remove forloop drop |
| `PUSH_INTERRUPT` | `[:PUSH_INTERRUPT, type]` | Signal break/continue |
| `POP_INTERRUPT` | `[:POP_INTERRUPT]` | Clear interrupt |

### Tablerow

| Instruction | Format | Description |
|-------------|--------|-------------|
| `TABLEROW_INIT` | `[:TABLEROW_INIT, var, loop_name, has_limit, has_offset, cols]` | Initialize tablerow |
| `TABLEROW_NEXT` | `[:TABLEROW_NEXT, continue_label, break_label]` | Advance with `<tr>`/`<td>` output |
| `TABLEROW_END` | `[:TABLEROW_END]` | Clean up tablerow |

### Counters

| Instruction | Format | Description |
|-------------|--------|-------------|
| `INCREMENT` | `[:INCREMENT, name]` | Increment counter, push new value |
| `DECREMENT` | `[:DECREMENT, name]` | Decrement counter, push new value |

### Cycle

| Instruction | Format | Description |
|-------------|--------|-------------|
| `CYCLE_STEP` | `[:CYCLE_STEP, identity, values]` | Advance cycle, push current value |
| `CYCLE_STEP_VAR` | `[:CYCLE_STEP_VAR, var_name, values]` | Cycle with variable group |

### Capture

| Instruction | Format | Description |
|-------------|--------|-------------|
| `PUSH_CAPTURE` | `[:PUSH_CAPTURE]` | Start capturing output |
| `POP_CAPTURE` | `[:POP_CAPTURE]` | End capture, push captured string |

### Partials

| Instruction | Format | Description |
|-------------|--------|-------------|
| `RENDER_PARTIAL` | `[:RENDER_PARTIAL, name, args]` | Render partial (isolated scope) |
| `INCLUDE_PARTIAL` | `[:INCLUDE_PARTIAL, name, args]` | Include partial (shared scope) |
| `CONST_RENDER` | `[:CONST_RENDER, name, args]` | Compile-time render (lowered) |
| `CONST_INCLUDE` | `[:CONST_INCLUDE, name, args]` | Compile-time include (lowered) |

### Stack Operations

| Instruction | Format | Description |
|-------------|--------|-------------|
| `DUP` | `[:DUP]` | Duplicate stack top |
| `POP` | `[:POP]` | Discard stack top |
| `BUILD_HASH` | `[:BUILD_HASH, count]` | Pop `count*2` items, push Hash |
| `STORE_TEMP` | `[:STORE_TEMP, index]` | Pop and store in temp slot |
| `LOAD_TEMP` | `[:LOAD_TEMP, index]` | Push from temp slot |

### Range

| Instruction | Format | Description |
|-------------|--------|-------------|
| `NEW_RANGE` | `[:NEW_RANGE]` | Pop end, pop start, push range |

### Misc

| Instruction | Format | Description |
|-------------|--------|-------------|
| `IFCHANGED_CHECK` | `[:IFCHANGED_CHECK, tag_id]` | Pop captured, output if changed |
| `NOOP` | `[:NOOP]` | No operation |

## Example: Simple Output

```liquid
{{ name | upcase }}
```

```
FIND_VAR "name"
CALL_FILTER "upcase", 0
WRITE_VALUE
HALT
```

## Example: For Loop

```liquid
{% for item in items %}{{ item }}{% endfor %}
```

```
FIND_VAR "items"
FOR_INIT "item", "item-items", false, false, false, false
LABEL 1
PUSH_FORLOOP
FOR_NEXT 2, 3
ASSIGN_LOCAL "item"
FIND_VAR "item"
WRITE_VALUE
JUMP 1
LABEL 2
POP_FORLOOP
JUMP 1
LABEL 3
FOR_END
POP_FORLOOP
HALT
```

## Optimization Passes

The compiler applies several optimization passes (see `lib/liquid_il/compiler.rb`):

1. **Constant folding** - Evaluate constant expressions at compile time
2. **Filter folding** - Fold filters on constants (e.g., `{{ "hello" | upcase }}` → `"HELLO"`)
3. **Dead code elimination** - Remove unreachable code after jumps
4. **WRITE_RAW merging** - Combine consecutive raw writes
5. **Loop invariant hoisting** - Move invariant lookups outside loops
6. **Constant propagation** - Replace variables with known constant values

Use `--no-optimize` to see unoptimized IL.
