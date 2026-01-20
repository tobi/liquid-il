# LiquidIL

**A complete Liquid template implementation, 100% "vibe coded" by Claude Code.**

This project is a proof of concept demonstrating what happens when you point an AI coding agent at a comprehensive test suite and say "make all the tests pass." The result: a fully functional Liquid template engine that passes 4,424 tests and achieves 99.8% compatibility with the reference implementation.

## The Experiment

Can an AI build a working programming language implementation from scratch, guided only by a test suite?

**Setup:**
- [Claude Code](https://claude.com/claude-code) (Anthropic's AI coding agent)
- [liquid-spec](https://github.com/Shopify/liquid-spec) (4,424 executable specifications for Liquid)
- Zero prior Liquid implementation code

**Process:**
1. Run tests
2. Read failures
3. Write code to fix them
4. Repeat

**Result:**
```
$ bundle exec liquid-spec run adapter.rb

Features: core, runtime_drops

Basics ................................. 525/525 passed
Liquid Ruby ............................ 1717/1717 passed
Shopify Production Recordings .......... 2182/2182 passed
Liquid Ruby (Lax Mode) ................. skipped (needs lax_parsing)
Shopify Theme Dawn ..................... skipped (needs shopify_tags, shopify_objects, shopify_filters)

Total: 4424 passed, 0 failed, 0 errors. Max complexity reached: 1000/1000
```

When compared against the reference Ruby implementation:
```
$ rake matrix

4425 matched, 9 different (99.8% compatible)
```

## What is Liquid?

[Liquid](https://shopify.github.io/liquid/) is a template language created by Shopify, used by millions of stores and sites. It's designed to be safe for user-facing templates with no access to system resources.

```liquid
{% for product in products %}
  <h2>{{ product.title | upcase }}</h2>
  {% if product.available %}
    <p>Only {{ product.inventory | default: "a few" }} left!</p>
  {% endif %}
{% endfor %}
```

## Architecture

LiquidIL compiles templates to an intermediate language (IL) that can be executed via three different strategies:

```
Source → Lexer → Parser → IL → [Optimizer] → Linker → Execution Strategy
```

### Execution Strategies

LiquidIL implements three distinct execution backends, each with different trade-offs:

| Strategy | Compile | Render | Best For |
|----------|---------|--------|----------|
| **VM Interpreter** | Fast | Moderate | Development, one-shot renders |
| **Compile to state machine Ruby** | Slow | Fast | High-traffic cached templates |
| **Compile to structured Ruby** | Moderate | Moderate | Readable generated code |

#### 1. VM Interpreter (`liquid_il_interpreter.rb`)

The IL instructions are executed directly by a stack-based virtual machine. Each instruction is dispatched via a case statement.

```ruby
template = context.parse(source)  # Parse to IL
template.render(assigns)          # Execute via VM
```

**Pros:** Fast compile, simple debugging, full feature support
**Cons:** Dispatch overhead on every instruction

#### 2. Compile to State Machine Ruby (`liquid_il_compiled_statemachine.rb`)

Compiles IL to a Ruby proc containing a state machine with a dispatch loop. The generated code mirrors the VM structure but runs as native Ruby.

```ruby
template = context.parse(source)
compiled = LiquidIL::Compiler::Ruby.compile(template)
compiled.render(assigns)
```

**Generated code example:**
```ruby
loop do
  case pc
  when 0 then output << "Hello "; pc = 1
  when 1 then stack << scope.lookup("name"); pc = 2
  when 2 then output << stack.pop.to_s; pc = 3
  when 3 then break
  end
end
```

**Pros:** ~1.85x faster render than liquid_ruby, predictable performance
**Cons:** 7x slower compile (string generation + eval overhead)

#### 3. Compile to Structured Ruby (`liquid_il_structured.rb`)

Compiles IL to idiomatic Ruby with native control flow (if/else, each) instead of a state machine. Produces readable, "pretty" Ruby code.

```ruby
template = context.parse(source)
compiled = LiquidIL::Compiler::Structured.compile(template)
compiled.render(assigns)
```

**Generated code example:**
```ruby
output << "Hello "
output << scope.lookup("name").to_s
if scope.lookup("show_greeting")
  output << "Welcome!"
end
```

**Pros:** Generates idiomatic Ruby, easier to debug
**Cons:** Complex IL patterns (deep boolean chains, partials) fall back to VM

### Optimizer

The optimizer is optional and applies compile-time transformations:
- **Constant folding** - Evaluate constant expressions, comparisons, and pure filters at compile time
- **Instruction fusion** - Merge `FIND_VAR` + property lookups into single `FIND_VAR_PATH` opcode
- **Dead code elimination** - Remove unreachable code after unconditional jumps
- **Write merging** - Combine consecutive `WRITE_RAW` instructions
- **Partial inlining** - Pre-compile `{% render %}` / `{% include %}` partials when file system available

### Why IL?

The IL approach was not planned—it emerged from the "vibe coding" process. The AI found it easier to emit simple instructions than to build and walk an AST. This accidentally produced some nice properties:

- **Simple instruction encoding** - Just arrays: `[:WRITE_RAW, "hello"]`
- **Easy optimization** - Peephole passes on linear instruction streams
- **Clear execution model** - Stack machine with explicit control flow
- **Multiple backends** - Same IL can target VM, state machine, or structured Ruby

### IL Examples

**Simple output with variable:**
```
$ bin/liquidil parse 'Hello {{ name }}!' --no-color

[  0]     WRITE_RAW         "Hello "
[  1]     FIND_VAR          "name"                # → name
[  2]     WRITE_VALUE                             # pop → output
[  3]     WRITE_RAW         "!"
[  4]     HALT                                    # end execution
```

**Conditional:**
```
$ bin/liquidil parse '{% if user %}Hello {{ user.name }}{% endif %}' --no-color

[  0]     FIND_VAR          "user"                # → user
[  1]     IS_TRUTHY                               # pop → bool
[  2]     JUMP_IF_FALSE     L0                    # pop, jump if falsy
[  3]     WRITE_RAW         "Hello "
[  4]     FIND_VAR          "user"                # → user
[  5]     LOOKUP_CONST_KEY  "name"                # pop obj → obj.name
[  6]     WRITE_VALUE                             # pop → output
[  7]  L0:
[  8]     HALT                                    # end execution
```

**Filter chain:**
```
$ bin/liquidil parse '{{ "hello" | upcase | split: "" | join: "-" }}' --no-color

[  0]     CONST_STRING      "hello"
[  1]     CALL_FILTER       "upcase", 0           # 0 args
[  2]     CONST_STRING      ""
[  3]     CALL_FILTER       "split", 1            # 1 args
[  4]     CONST_STRING      "-"
[  5]     CALL_FILTER       "join", 1             # 1 args
[  6]     WRITE_VALUE                             # pop → output
[  7]     HALT                                    # end execution
```

**For loop:**
```
$ bin/liquidil parse '{% for i in (1..3) %}{{ i }}{% endfor %}' --no-color

[  0]     CONST_INT         1                     # → 1
[  1]     CONST_INT         3                     # → 3
[  2]     NEW_RANGE                               # pop end, start → range
[  3]     JUMP_IF_EMPTY     L3                    # peek, jump if empty
[  4]     FOR_INIT          "i"
[  5]     PUSH_SCOPE
[  6]     PUSH_FORLOOP
[  7]  L0:
[  8]     FOR_NEXT          L1, L2                # continue, break
[  9]     ASSIGN_LOCAL      "i"
[ 10]     FIND_VAR          "i"                   # → i
[ 11]     WRITE_VALUE                             # pop → output
[ 12]     JUMP_IF_INTERRUPT L2                    # jump if break/continue
[ 13]  L1:
[ 14]     POP_INTERRUPT
[ 15]     JUMP              L0
[ 16]  L2:
...
[ 24]     HALT                                    # end execution
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete instruction reference (55 IL operations).

## Usage

```ruby
require "liquid_il"

# One-shot render
output = LiquidIL.render("Hello {{ name }}!", name: "World")
# => "Hello World!"

# Parse once, render many times
template = LiquidIL::Template.parse("{{ x | plus: 1 }}")
template.render(x: 1)  # => "2"
template.render(x: 41) # => "42"

# With a context for file system access (includes/renders)
ctx = LiquidIL::Context.new(file_system: my_fs)
template = ctx.parse("{% render 'header' %}")
template.render(title: "Home")
```

## Running Tests

This project uses [liquid-spec](https://github.com/Shopify/liquid-spec) for testing.

```bash
# Install dependencies
bundle install

# Run all specs
rake spec

# Compare against reference implementation
rake matrix

# Run benchmarks
rake bench

# Run specific adapter
bundle exec liquid-spec run spec/liquid_il_interpreter.rb -n "for"

# Available adapters:
#   spec/liquid_il_interpreter.rb           - VM interpreter (no optimizer)
#   spec/liquid_il_interpreter_optimized.rb - VM interpreter + optimizer
#   spec/liquid_il_compiled_statemachine.rb - State machine Ruby compiler
#   spec/liquid_il_structured.rb            - Structured Ruby compiler
```

## What This Proves

This project demonstrates that:

1. **Comprehensive test suites are powerful specifications.** liquid-spec contains enough detail that an AI could build a compatible implementation without reading any prose documentation or existing code.

2. **"Vibe coding" can produce working software.** The iterative process of running tests, reading failures, and writing fixes—guided by an AI—produced a real, functional template engine.

3. **AI coding agents are here.** Claude Code successfully navigated thousands of edge cases, error conditions, and semantic subtleties to achieve near-perfect compatibility.

## Performance

LiquidIL offers multiple execution strategies with different compile/render trade-offs.

**Benchmark results** (vs reference liquid_ruby implementation):

| Adapter | Compile | Render | Total |
|---------|---------|--------|-------|
| `liquid_ruby` (reference) | 1.0x | 1.0x | baseline |
| `liquid_il_interpreter` | 3.5x slower | 1.6x slower | slower |
| `liquid_il_interpreter_optimized` | 3.5x slower | 1.6x slower | slower |
| `liquid_il_compiled_statemachine` | 7.2x slower | **1.85x faster** | varies |
| `liquid_il_structured` | 5.0x slower | 1.5x slower | slower |

**Key insight:** The state machine compiler wins on render (1.85x faster) but loses on compile (7.2x slower). For templates rendered many times from cache, the state machine compiler pays off after ~4 renders.

**Partials-heavy ecommerce workloads** show larger gains for the compiled backends:

| Benchmark | Speedup |
|-----------|---------|
| Theme product page (15 partials) | **2.54x faster** |
| Theme cart page (12 partials) | **2.25x faster** |
| Theme collection page (12 products) | **5.20x faster** |
| Notification center (15 notifications) | **1.92x faster** |

Run benchmarks yourself:
```bash
rake bench              # Core benchmarks (all adapters)
rake bench_partials     # Partials/ecommerce benchmarks
```

## Optimization Passes

LiquidIL applies extensive optimizations at both IL compile time and Ruby code generation time.

### IL Optimizer (compile-time)

| Pass | Description |
|------|-------------|
| **Constant folding** | Evaluate `IS_TRUTHY`, `BOOL_NOT`, `COMPARE`, `CONTAINS` on constants |
| **Constant filter folding** | Evaluate pure filters on constant inputs (e.g., `{{ "hello" \| upcase }}` → `"HELLO"`) |
| **Constant write folding** | Merge `CONST_*` + `WRITE_VALUE` → `WRITE_RAW` |
| **Path collapsing** | Merge `LOOKUP_CONST_KEY` chains into single `LOOKUP_CONST_PATH` |
| **Variable path fusion** | Merge `FIND_VAR` + `LOOKUP_CONST_PATH` → `FIND_VAR_PATH` |
| **Redundant truthy removal** | Remove `IS_TRUTHY` after `COMPARE`/`CONTAINS`/`BOOL_NOT` |
| **Jump optimization** | Remove jumps to immediately following labels |
| **Write merging** | Combine consecutive `WRITE_RAW` instructions |
| **Dead code elimination** | Remove unreachable code after unconditional `JUMP`/`HALT` |
| **Capture folding** | Fold `{% capture %}` blocks with only static content |
| **Empty write removal** | Remove `WRITE_RAW` with empty strings |
| **Constant propagation** | Replace `FIND_VAR` with known constant values |
| **Loop invariant hoisting** | Hoist invariant lookups outside `{% for %}` loops |
| **Repeated lookup caching** | Cache repeated variable lookups with `DUP`+`STORE_TEMP` |
| **Partial inlining** | Pre-compile `{% render %}`/`{% include %}` partials |

### Ruby Codegen (State Machine Compiler)

| Optimization | Description |
|--------------|-------------|
| **Interrupt check elision** | Skip `has_interrupt?` guards when no `{% break %}`/`{% continue %}` in template |
| **ForloopDrop elision** | Skip `ForloopDrop` allocation when `forloop` variable unused |
| **Local temp variables** | Use Ruby locals (`t0`) instead of scope method calls |
| **Direct expression generation** | Fold stack operations into single Ruby expressions |
| **Write batching** | Combine consecutive raw writes into single `<<` |
| **Capture mode detection** | Use simpler output code when no `{% capture %}` blocks |

### Example: Before/After Optimization

**Template:** `{{ product.name }} - ${{ product.price }}`

**Unoptimized (stack-based):**
```ruby
stack << scope.lookup("product")
stack << stack.last
scope.store_temp(0, stack.pop)
stack << lookup_property(stack.pop, "name")
v = stack.pop
output << v.to_s unless scope.has_interrupt?
output << " - $" unless scope.has_interrupt?
stack << scope.load_temp(0)
stack << lookup_property(stack.pop, "price")
v = stack.pop
output << v.to_s unless scope.has_interrupt?
```

**Optimized (direct expressions):**
```ruby
t0 = scope.lookup("product")
output << lookup_property(t0, "name").to_s
output << " - $"
output << lookup_property(t0, "price").to_s
```

## Limitations

- **Limited error messages** - Some error formats differ from reference
- **No liquid-c compatibility** - Missing the C extension optimizations
- **Incomplete edge cases** - 9 known differences in the matrix comparison

## Contributing

This repo exists primarily as a demonstration. But if you're interested in AI-assisted development, test-driven design, or template engine internals, feel free to explore!

## License

MIT

---

*Built with [Claude Code](https://claude.com/claude-code) and [liquid-spec](https://github.com/Shopify/liquid-spec)*
