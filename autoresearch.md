# Autoresearch: Faster Compile + Render (total_µs)
> **NOTE**: Every 2-3 experiments, call `advisor()` to get a second opinion from the helper model.

## Objective
Reduce `compile_µs + render_warm_µs` (total cycle time) for LiquidIL without breaking correctness.

**Previous baseline**: ~376µs compile, ~720µs render (warm) = ~1096µs total.
**Current best**: ~270µs compile, ~735µs render = ~1005µs total.

The compile pipeline is:
1. **Lexer** (TemplateLexer + ExpressionLexer) - Tokenize source
2. **Parser** - Parse tokens, emit IL instructions directly
3. **IL Optimization Passes** - 23 passes (many skipped in Ruby compiler mode)
4. **IL Linking** - Resolve labels to indices
5. **RubyCompiler** - Compile IL to Ruby source, then `eval` it

Ruby compiler mode skips passes `[0, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22]`.

## Metrics
- **Primary**: `total_µs` (µs, lower is better) — compile + render_warm combined
- **Secondary**: `compile_µs`, `render_warm_µs`, `render_cold_µs`, `compile_allocs`, `render_warm_allocs`, `total_allocs`

## How to Run
`./autoresearch.sh` — outputs `METRIC` lines.

## Render Benchmarks Explained
- **Cold render**: first render immediately after parse (no JIT warmup). Represents worst-case latency.
- **Warm render**: render after 3 warmup renders. Represents steady-state throughput.
- Primary metric uses warm render (most representative of real-world usage).

## Files in Scope
- `lib/liquid_il/lexer.rb` - Two-stage lexer (template + expression)
- `lib/liquid_il/parser.rb` - Recursive descent parser, emits IL
- `lib/liquid_il/compiler.rb` - IL optimization passes, linking
- `lib/liquid_il/ruby_compiler.rb` - IL → Ruby code generation + eval
- `lib/liquid_il/il.rb` - IL instruction definitions and linker
- `lib/liquid_il/passes.rb` - Pass configuration
- `lib/liquid_il/optimizer.rb` - Optimizer wrapper
- `lib/liquid_il.rb` - Main module entry point
- `lib/liquid_il/filters.rb` - Filter implementations
- `lib/liquid_il/runtime_helpers.rb` - Runtime helper procs
- `lib/liquid_il/context.rb` - Context and scope management

## Off Limits
- Runtime render correctness (must pass tests)
- Public API surface (Context.parse, Template.render)

## Constraints
- Syntax checks must pass
- Unit tests must pass (test/liquid_il_test.rb)
- No new dependencies
- Render output must be identical to baseline

## What's Been Tried

### Wins (kept, cumulative ~30µs compile savings)
- **#2**: Optimized Ruby compiler pass set [7,9,20,21] -5µs
- **#3**: Merged partial scan + feature flag detection into single pass -5µs
- **#4**: Conditional fused_peephole skip when no passes enabled -11µs
- **#6**: Optimized IL.link: while loop + direct opcode comparisons -10µs
- **#9**: Direct Ruby string generation in build_expression (eliminate Expr trees) -100µs potential
- **#16**: Remove dead if/else in parse_variable_lookup -5µs
- **#18**: Fuse FIND_VAR + LOOKUP_CONST_KEY into FIND_VAR_PATH at emit time -13µs
- **#19**: Class-level partial compilation cache -17µs
- **#25**: Fuse IL.link + strip_labels into 2-pass algorithm -7µs
- **#26**: TemplateLexer.scan_raw_token: String#index instead of byte scanning -8µs
- **#28**: Inline common opcodes in generate_body -2µs
- **#33**: Split feature flag scan from partial scan, detect flags inline in generate_body -8µs

### Discarded (no measurable improvement)
- **#5**: Adding passes 7, 9, 20 to Ruby compiler — overhead of extra scans > savings
- **#8**: String concatenation vs interpolation in inline_output_append — noise
- **#11**: Pre-scanning all positions for statement classification — worse (visits dead positions)
- **#12**: Skip STRING_RETURN_SUFFIXES regex for ')' endings — noise
- **#13**: Inline simple case branches into generate_body — worse (more code << operations)
- **#14**: Fast path in optimize when only strip_labels — noise
- **#15**: Cache peek results per position — noise (cache overhead = savings)
- **#17**: Add passes 4, 5 to Ruby compiler — overhead > savings
- **#21**: Inline common opcodes (v1) — worse (more code << operations)
- **#22**: Replace case dispatch with while/if/elsif in parse_property_chain — noise
- **#23**: Replace %w[].include? with direct comparisons — noise
- **#24**: Skip strip_labels for Ruby compiler — tests failed (LABEL instructions needed)
- **#27**: Merge detect_uses_interrupts into generate_ruby scan — worse (extra case clause)
- **#29**: Direct IL emission helpers in parser — noise (Ruby method call overhead fundamental)
- **#30**: byteslice + rstrip in extract_tag_args — worse (allocation overhead)
- **#31**: ExpressionLexer EOS check optimization — noise (method call = int compare)
- **#32**: Inline DOT case in parse_variable_lookup — worse (extra Ruby code)

### Key Insights
- Ruby method call overhead (~50ns) is hard to avoid without C extension
- String allocation overhead often exceeds CPU savings from C-level operations
- The most impactful optimizations: reducing passes, merging scans, caching compiled code
- Parser is ~90µs, Codegen is ~80µs, IL Builder ~15µs (remaining targets)
