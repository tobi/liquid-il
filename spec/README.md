# Testing with liquid-spec

This directory contains the adapter that connects LiquidIL to [liquid-spec](https://github.com/Shopify/liquid-spec), the executable specification for Liquid template engines.

## The Power of Executable Specifications

liquid-spec is remarkable: it contains **4,424 executable tests** that fully specify Liquid's behavior. Each test defines:
- Input template
- Environment variables
- Expected output
- Hints for implementers

This made it possible for Claude Code to build LiquidIL entirely through test-driven development—without ever reading the reference implementation's source code.

## Results

```
$ rake spec

Basics ................................. 525/525 passed
Liquid Ruby ............................ 1717/1717 passed
Shopify Production Recordings .......... 2182/2182 passed

Total: 4424 passed, 0 failed, 0 errors
```

### Compatibility Matrix

```
$ rake matrix

4425 matched, 9 different (99.8% compatible)
```

The 9 differences are minor error message formatting variations.

### Benchmarks

```
$ rake bench

Overall:
  Compile: liquid_ruby ran 1.24x faster than LiquidIL
  Render:  liquid_ruby ran 1.79x faster than LiquidIL
```

Not bad for a "vibe coded" implementation! The reference implementation has years of optimization. LiquidIL prioritized correctness over performance.

## How the Adapter Works

The adapter (`liquid_il.rb`) implements two callbacks:

```ruby
# Parse template source into a compiled template object
LiquidSpec.compile do |ctx, source, options|
  ctx[:template] = LiquidIL::Template.parse(source)
end

# Render a compiled template with assigns
LiquidSpec.render do |ctx, assigns, options|
  # Set up context with file system, registers, etc.
  liquid_ctx = LiquidIL::Context.new(
    file_system: FileSystemAdapter.new(options[:registers][:file_system]),
    registers: options[:registers],
    strict_errors: options[:strict_errors]
  )

  # Bind template to context and render
  bound_template = LiquidIL::Template.new(
    ctx[:template].source,
    ctx[:template].instructions,
    ctx[:template].spans,
    liquid_ctx
  )

  bound_template.render(assigns)
end
```

## Running Tests

```bash
# Run all specs
rake spec

# Run specific pattern
bundle exec liquid-spec run spec/liquid_il.rb -n "for"

# Compare against reference
rake matrix

# Run benchmarks
rake bench

# Inspect a specific test
rake inspect[test_name]
```

## What This Proves About liquid-spec

liquid-spec is detailed enough to serve as a complete specification. An AI with no prior knowledge of Liquid's internals was able to:

1. Build a lexer that handles all edge cases
2. Build a parser that emits correct IL
3. Implement all 50+ filters
4. Handle complex control flow (for, if, case, tablerow)
5. Support render/include with proper scoping
6. Match error handling behavior

All by reading test failures and writing code to fix them.

This is a testament to the quality of liquid-spec as executable documentation.
