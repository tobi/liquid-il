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
Basics ................................. 525/525 passed
Liquid Ruby ............................ 1717/1717 passed
Shopify Production Recordings .......... 2182/2182 passed

Total: 4424 passed, 0 failed, 0 errors
```

When compared against the reference Ruby implementation:
```
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
Source → Lexer → Parser → IL → Linker → VM
```

### Why IL?

The IL approach was not planned—it emerged from the "vibe coding" process. The AI found it easier to emit simple instructions than to build and walk an AST. This accidentally produced some nice properties:

- **Simple instruction encoding** - Just arrays: `[:WRITE_RAW, "hello"]`
- **Easy optimization** - Peephole passes on linear instruction streams
- **Clear execution model** - Stack machine with explicit control flow

### Example

Template:
```liquid
{% if user %}Hello {{ user.name | upcase }}{% endif %}
```

Compiles to:
```
FIND_VAR "user"
IS_TRUTHY
JUMP_IF_FALSE L1
WRITE_RAW "Hello "
FIND_VAR "user"
LOOKUP_CONST_KEY "name"
CALL_FILTER "upcase" 0
WRITE_VALUE
LABEL L1
HALT
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for full details on the instruction set and VM design.

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

Note: The Gemfile references a local path for liquid-spec. Update it to point to your checkout of liquid-spec or a published gem location.

## What This Proves

This project demonstrates that:

1. **Comprehensive test suites are powerful specifications.** liquid-spec contains enough detail that an AI could build a compatible implementation without reading any prose documentation or existing code.

2. **"Vibe coding" can produce working software.** The iterative process of running tests, reading failures, and writing fixes—guided by an AI—produced a real, functional template engine.

3. **AI coding agents are here.** Claude Code successfully navigated thousands of edge cases, error conditions, and semantic subtleties to achieve near-perfect compatibility.

## Limitations

This is a proof of concept, not production software:

- **No performance optimization** - The reference implementation has years of tuning
- **Limited error messages** - Some error formats differ from reference
- **No liquid-c compatibility** - Missing the C extension optimizations
- **Incomplete edge cases** - 9 known differences in the matrix comparison

## Contributing

This repo exists primarily as a demonstration. But if you're interested in AI-assisted development, test-driven design, or template engine internals, feel free to explore!

## License

MIT

---

*Built with [Claude Code](https://claude.com/claude-code) and [liquid-spec](https://github.com/Shopify/liquid-spec)*
