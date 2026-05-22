# Autoresearch: Faster Compile Time

## Objective
Make `LiquidIL::Template.parse()` (compile) much faster without negatively affecting runtime render performance.

**Current baseline**: ~370 µs compile, ~475 µs render (for a complex template with for loops, if statements, filters, partials).

The compile pipeline is:
1. **Lexer** (TemplateLexer + ExpressionLexer) - Tokenize source
2. **Parser** - Parse tokens, emit IL instructions directly  
3. **IL Optimization Passes** - 23 passes (many skipped in Ruby compiler mode)
4. **IL Linking** - Resolve labels to indices
5. **RubyCompiler** - Compile IL to Ruby source, then `eval` it

The Ruby compiler mode skips passes `[0, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22]` - so only passes 1, 2, 3, 4, 5, 7, 9, 20 run during compile.

## Metrics
- **Primary**: `compile_µs` (µs, lower is better) — compile time per template
- **Secondary**: `render_µs` (µs) — render time, must not regress significantly

## How to Run
`./autoresearch.sh` — outputs `METRIC compile_µs=N` and `METRIC render_µs=N`.

## Files in Scope
- `lib/liquid_il/lexer.rb` - Two-stage lexer (template + expression)
- `lib/liquid_il/parser.rb` - Recursive descent parser, emits IL
- `lib/liquid_il/compiler.rb` - IL optimization passes, linking
- `lib/liquid_il/ruby_compiler.rb` - IL → Ruby code generation + eval
- `lib/liquid_il/il.rb` - IL instruction definitions and linker
- `lib/liquid_il/passes.rb` - Pass configuration
- `lib/liquid_il/optimizer.rb` - Optimizer wrapper
- `lib/liquid_il.rb` - Main module entry point
- `lib/liquid_il/filters.rb` - Filter implementations (loaded at require time)
- `lib/liquid_il/runtime_helpers.rb` - Runtime helper procs
- `lib/liquid_il/context.rb` - Context and scope management

## Off Limits
- Runtime render correctness (must pass tests)
- Runtime render performance (should not regress >10%)
- Public API surface (Context.parse, Template.render)

## Constraints
- Syntax checks must pass
- Unit tests must pass (test/liquid_il_test.rb)
- No new dependencies
- Render output must be identical to baseline

## What's Been Tried
(Initial session - no experiments yet)
