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

LiquidIL compiles templates to an intermediate language (IL) that runs on a stack-based virtual machine. This is different from Shopify's reference implementation which uses an AST interpreter.

```
Source → Lexer → Parser → IL → [Optimizer] → Linker → VM
```

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

This project uses [liquid-spec](https://github.com/Shopify/liquid-spec) for testing. You'll need to set up the dependency first:

```bash
# Install dependencies
bundle install

# Run all specs
rake spec

# Compare against reference implementation
rake matrix

# Run specific test pattern
bundle exec liquid-spec run adapter.rb -n "for"
```

Note: The Gemfile references a local path for liquid-spec. Update it to point to your checkout of liquid-spec or a published gem location. See [spec/README.md](spec/README.md) for more details on how testing works.

## What This Proves

This project demonstrates that:

1. **Comprehensive test suites are powerful specifications.** liquid-spec contains enough detail that an AI could build a compatible implementation without reading any prose documentation or existing code.

2. **"Vibe coding" can produce working software.** The iterative process of running tests, reading failures, and writing fixes—guided by an AI—produced a real, functional template engine.

3. **AI coding agents are here.** Claude Code successfully navigated thousands of edge cases, error conditions, and semantic subtleties to achieve near-perfect compatibility.

## Performance

LiquidIL includes an ahead-of-time (AOT) Ruby compiler that compiles IL to native Ruby procs for maximum render performance.

**Benchmark results** (geometric mean vs reference Ruby implementation):

| Adapter | Render Speed |
|---------|--------------|
| `liquid_il` (VM interpreter) | 0.58x (slower) |
| `liquid_il_compiled` (AOT) | **1.27x faster** |
| `liquid_il_optimized_compiled` (AOT + optimizer) | **1.50x faster** |

**Partials-heavy ecommerce workloads** show even larger gains:

| Benchmark | Speedup |
|-----------|---------|
| Theme product page (15 partials) | **2.54x faster** |
| Theme cart page (12 partials) | **2.25x faster** |
| Theme collection page (12 products) | **5.20x faster** |
| Notification center (15 notifications) | **1.92x faster** |

Run benchmarks yourself:
```bash
rake bench              # Core benchmarks
ruby bench_partials.rb  # Partials/ecommerce benchmarks
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
