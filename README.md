# LiquidIL

A high-performance [Liquid](https://shopify.github.io/liquid/) template engine that compiles templates to optimized Ruby via an Intermediate Language (IL).

**Pipeline:** Source → Lexer → Parser → IL → Optimizer → Structured Compiler → Ruby

Templates are parsed into an IL instruction set, optimized through multiple passes (constant folding, dead code elimination, partial inlining, etc.), then compiled to YJIT-friendly Ruby with native control flow — no interpreter loop, no VM.

## Quick Start

```ruby
require "liquid_il"

# One-shot render
LiquidIL.render("Hello {{ name }}!", "name" => "World")
# => "Hello World!"

# Parse once, render many times
template = LiquidIL.parse("{{ greeting }}, {{ name }}!")
template.render("greeting" => "Hi", "name" => "Alice")
# => "Hi, Alice!"
template.render("greeting" => "Hey", "name" => "Bob")
# => "Hey, Bob!"
```

## Context

Use `Context` for templates that need a file system (partials), registers, or strict error mode:

```ruby
ctx = LiquidIL::Context.new(
  file_system: my_file_system,  # responds to #read(name) -> String
  strict_errors: false,
  registers: {}
)

template = ctx.parse("{% include 'header' %} Hello {{ name }}!")
template.render("name" => "World")
```

## Generating Standalone Ruby

Compiled templates can be exported as standalone Ruby modules. The generated code depends on `liquid_il` for runtime helpers (Scope, Filters, StructuredHelpers) but is otherwise self-contained.

```ruby
template = LiquidIL.parse("Hello {{ name | upcase }}!")

# Get Ruby source as a string
ruby_source = template.to_ruby("Greeting")

# Or write directly to a file
template.write_ruby("greeting.rb", module_name: "Greeting")
```

The generated module:

```ruby
# greeting.rb (auto-generated)
require "liquid_il"

module Greeting
  extend self

  def render(assigns = {}, render_errors: true)
    # ... compiled template code ...
  end
end
```

Use it:

```ruby
require_relative "greeting"
Greeting.render("name" => "World")  # => "Hello WORLD!"
```

## CLI

```bash
# Render a template
bin/liquidil render "Hello {{ name }}" -e name=World

# Show IL instructions
bin/liquidil parse "{% for i in (1..3) %}{{ i }}{% endfor %}"

# Show generated Ruby
bin/liquidil compile "{{ x | upcase }}"

# Parse, show IL, then render
bin/liquidil eval "{{ x | plus: y }}" -e x=2 -e y=3

# Show optimization passes
bin/liquidil passes
```

## Architecture

### Pipeline

```
Source Text
    ↓
 Lexer (StringScanner, two-stage: template + expression)
    ↓
 Parser (recursive descent → IL instructions)
    ↓
 IL (flat instruction array with labels + jumps)
    ↓
 Optimizer (20+ passes: const folding, dead code, partial inlining, ...)
    ↓
 Linker (resolve labels → instruction indices)
    ↓
 Structured Compiler (IL → Ruby proc with native if/else/each)
    ↓
 YJIT-friendly Ruby (direct execution, no interpreter dispatch)
```

### IL Instruction Set

The IL is a flat array of instructions, each a small Ruby Array:

```ruby
[:WRITE_RAW, "Hello "]           # Emit literal text
[:FIND_VAR, "name"]              # Look up variable
[:CALL_FILTER, "upcase", 0]      # Apply filter with 0 args
[:WRITE_VALUE]                   # Emit top of stack
[:JUMP_IF_FALSE, :label_3]       # Conditional branch
[:FOR_INIT, "item", ...]         # Begin for loop
[:HALT]                          # End of template
```

### Optimization Passes

The optimizer runs 20+ passes over the IL before compilation:

| Pass | Name | Effect |
|------|------|--------|
| 0 | Inline partials | Inline `include`/`render` at parse time |
| 1 | Fold const ops | `5 + 3` → `8` |
| 2 | Fold const filters | `"hello" \| upcase` → `"HELLO"` |
| 3 | Fold const writes | `FIND_VAR + WRITE_VALUE` → `WRITE_RAW` for constants |
| 4 | Collapse const paths | `LOOKUP a; LOOKUP b` → `FIND_VAR_PATH [a, b]` |
| 5 | Collapse var paths | Multi-step lookups → single instruction |
| 6 | Remove redundant truthy | Skip IS_TRUTHY after COMPARE |
| 7-9 | Cleanup | Remove NOOPs, dead jumps, merge raw writes |
| 10 | Remove unreachable | Dead code after unconditional jumps |
| 12 | Fold captures | `capture x; "literal"; endcapture` → `assign x "literal"` |
| 14 | Propagate constants | Track assigned constants through template |
| 20 | Fuse write+var | `FIND_VAR + WRITE_VALUE` → `WRITE_VAR` |
| 22 | Remove interrupt checks | Skip break/continue checks in loops without them |

### Structured Compiler

The structured compiler converts IL to Ruby with native control flow:

- `if/elsif/else/end` instead of JUMP_IF_FALSE + LABEL
- `collection.each_with_index` instead of FOR_INIT + FOR_NEXT
- Direct variable access instead of stack operations
- Partial bodies compiled inline as lambdas

This produces code that YJIT can optimize effectively — no megamorphic dispatch, no interpreter loop, predictable branch shapes.

## Test Suite

```bash
# Run unit tests
bundle exec rake unit

# Run liquid-spec (4000+ Liquid specifications)
bundle exec rake spec

# Run full suite (unit tests + liquid-spec)
bundle exec rake test

# Compare against reference Liquid implementation
bundle exec rake matrix
```

## Known Limitations

The structured compiler cannot handle a few edge cases:

- **Dynamic partial names** — `{% include variable_name %}` where the partial name isn't a string literal
- **Break/continue in included partials** — `{% include 'partial' %}` where the partial uses `{% break %}` inside a caller's for loop
- **Recursive partials** — Templates that include themselves (directly or mutually)

These affect ~1% of the liquid-spec test suite. All other templates (99%+) compile and execute correctly.
