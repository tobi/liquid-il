# LiquidIL

A high-performance [Liquid](https://shopify.github.io/liquid/) template engine that compiles templates to optimized Ruby via an Intermediate Language (IL).

**Pipeline:** Source → Lexer → Parser → IL → Optimizer → Structured Compiler → Ruby

Templates are parsed into an IL instruction set, optimized through multiple passes (constant folding, dead code elimination, partial inlining, etc.), then compiled to YJIT-friendly Ruby with native control flow — no interpreter loop, no VM.

## Why It's Fast

LiquidIL achieves its performance through a combination of compile-time decisions and runtime optimizations:

**Compile to native Ruby, not interpret.** Instead of walking an AST or dispatching bytecodes at runtime, LiquidIL compiles each template to a Ruby proc with real `if/else`, `each`, and local variables. YJIT then compiles *that* to machine code. The result is two levels of compilation — Liquid → Ruby → native — with zero interpreter overhead.

**Solve problems at the right level.** Constant folding happens during IL optimization (`"hello" | upcase` becomes `"HELLO"` at parse time). Filter dispatch is resolved during structured compilation (common filters like `upcase`, `escape`, `size` compile to direct Ruby calls, not method_missing). Type checks are eliminated at code generation when the compiler can prove a value's type.

**Zero-allocation hot paths.** The lexer uses `StringScanner#skip` instead of `scan`, deferring string extraction until needed. Expression lexers are reused (one instance per parse, reset via `reset_source`). IL instructions for zero-argument opcodes are pre-frozen constants. Frozen string tables avoid `Integer#to_s` for small numbers. Filter arguments are hoisted as frozen constants outside loops.

**Inline everything that can be inlined.** Comparisons (`==`, `<`, `>`) compile to native Ruby operators with a Numeric fast path. Filters compile to direct method calls. Partial templates compile as inline lambdas. The escape filter skips `CGI.escapeHTML` entirely when the input contains no special characters.

**Cache aggressively.** ISeq binaries are cached by source hash — repeated compilation of the same template loads from a binary cache instead of re-parsing Ruby source.

See [OPTIMIZATION_GUIDE.md](OPTIMIZATION_GUIDE.md) for detailed profiling data and future optimization paths.

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

Compiled templates can be exported as standalone Ruby modules. The generated code depends on `liquid_il` for runtime helpers (Scope, Filters, RuntimeHelpers) but is otherwise self-contained.

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

## Saving and Loading Compiled Templates (ISeq)

LiquidIL can persist compiled templates as RubyVM ISeq binaries.

```ruby
template = LiquidIL.parse("Hello {{ name }}")

# 1) Raw ISeq binary (fastest, minimal payload)
template.write_iseq("greeting.iseq")
restored = LiquidIL::Template.load_iseq("greeting.iseq", source: "Hello {{ name }}")
restored.render("name" => "World")
# => "Hello World"

# 2) Full cache payload (includes source/spans/partial constants)
template.write_cache("greeting.ilc")
restored2 = LiquidIL::Template.load_cache("greeting.ilc")
restored2.render("name" => "World")
# => "Hello World"
```

Low-level direct call (no Template wrapper):

```ruby
iseq = RubyVM::InstructionSequence.load_from_binary(File.binread("greeting.iseq"))
proc_obj = iseq.eval
scope = LiquidIL::Scope.new("name" => "World")
output = proc_obj.call(scope, restored.spans, restored.source)
# => "Hello World"
```

Notes:
- ISeq binaries are Ruby-version specific (and generally architecture-specific).
- Prefer `write_cache`/`load_cache` when you want metadata + better error locations.
- Use raw `write_iseq`/`load_iseq` for the smallest payload and fastest restore path.

See also: [`docs/compiled_templates.md`](docs/compiled_templates.md)

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
