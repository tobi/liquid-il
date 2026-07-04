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

## The Optimization Target

LiquidIL is optimized, by default and without tuning knobs, for one specific production workload:

> **Compile a template once, persist the compiled artifact (memcache / database), then in some other process — one that has never seen this template — fetch the artifact and execute it.**

```ruby
blob = memcache.get(key)                  # a compiled artifact string
LiquidIL.load_and_render(blob, assigns)   # load → render, cold
```

The hot path is therefore **deserialize → callable proc → first render**, *not* re-rendering a template already resident in memory. That single assumption drives every design decision, and there are no `optimize_for:`-style switches — the one default *is* the optimized configuration:

- **The emitted code is kept small.** The generated Ruby (and thus the ISeq binary) is the thing we load cold, and `RubyVM::InstructionSequence.load_from_binary` cost scales with binary size (~3µs/KB). Repeated codegen patterns are pulled into the runtime library instead of being emitted per-template, so the artifact carries as little code as possible.
- **The load process is optimized.** Artifacts are raw ISeq binaries in a thin framed envelope — no source, no spans (error locations are baked in as compile-time literals, so the artifact needs neither). Decoding is a magic-check plus a `byteslice`, not a Marshal object graph.
- **The source is not embedded.** Callers already hold their templates in a filesystem or database; the artifact stays lean and the source is refetched only if a Ruby-version change forces a recompile.

### The three render scenarios

Every render in production falls into one of three cache scenarios, and every benchmark in this repo reports all three (plus the artifact size that links them). These are **the** core optimization and test scenarios:

| scenario | what happens | dominated by |
|---|---|---|
| **cache-miss → render** | template never seen: parse + compile + render | parser + IL optimizer + codegen |
| **remote-hit → render** | compiled artifact fetched as a string (memcache/DB) → load → render | artifact size (~3µs/KB ISeq load) |
| **in-process → render** | template already loaded in this process → render | generated-code quality under JIT |

`rake bench` (alias `rake scenarios`) prints exactly this table against reference liquid; `rake liquid_vm:scenarios` adds Shopify/liquid-vm classic and SSA. Current standing (Ruby 4.0, YJIT, geomean over the common bench specs, 2026-07-04):

| adapter | cache-miss | remote-hit | in-process | artifact |
|---|---:|---:|---:|---:|
| liquid_il | **454µs** | **95µs** | **64µs** | 8.2KB |
| liquid_ruby | 446µs | — | 188µs | — |
| liquid_vm | 429µs | 107µs | 90µs | 1.7KB |
| liquid_vm_ssa | 1.01ms | 115µs | 97µs | 1.8KB |

remote-hit is the production workload and the primary target; in-process shows the ceiling of the generated code; cache-miss is the cost of a cold fleet. LiquidIL currently wins remote-hit and in-process outright, is at parity with reference liquid on cache-miss (within 6% of liquid-vm), and still trails liquid-vm's compact bytecode on artifact size — the remaining lever on the biggest templates. The plan to win all four columns, with per-tranche results, is [docs/win_all_scenarios.md](docs/win_all_scenarios.md).

### Runtime environment assumptions

LiquidIL assumes and is tuned for:

- **Ruby 4+ with a JIT always enabled** (YJIT today, ZJIT later). Emitted code is written to be JIT-friendly: minimal branching, minimal allocation, and hot patterns lifted into the runtime so the JIT compiles them **once** and reuses them across every template.
- **The LiquidIL runtime already loaded and warm** in the executing process (the JIT has already compiled the shared helpers). Only the per-template ISeq is cold.
- **Templates delivered as compiled string artifacts** that are loaded and executed, rather than re-parsed.

### Memory-bounded template cache

For processes that render the same templates repeatedly, an optional LRU cache loads each artifact once and keeps the live proc resident, evicting least-recently-used entries when a byte budget is exceeded:

```ruby
cache = LiquidIL::TemplateCache.new(max_bytes: 64 * 1024 * 1024)

blob = memcache.get(key)             # fetch the compiled artifact
cache.render(key, blob, assigns)     # loads+caches on first use, reuses thereafter
```

The budget is accounted by the summed size of the loaded artifacts; once it is exceeded, the least-recently-used templates are dropped. Each entry remembers its blob's CRC32, so republishing a template under the same key transparently reloads it.

### The artifact format

`Template#to_artifact` produces a framed binary (`"LQIL"` magic, format version, Ruby version/platform stamp, content digest, length-prefixed segments — see `lib/liquid_il/artifact.rb`). Loading an artifact built by a different Ruby raises `LiquidIL::StaleArtifactError` (a mismatched ISeq binary can crash the VM, so it is never fed to `load_from_binary`); a damaged blob raises `LiquidIL::CorruptArtifactError`. In both cases the caller recompiles from its own copy of the source and re-persists.

### Measured cold-path numbers

`rake bench:cold` (Ruby 4.0, YJIT, medians; hard-fails unless artifact output == fresh-compile output == reference liquid gem output):

| spec | artifact | decode | ISeq load | cold total | warm render |
|---|---|---|---|---|---|
| bench_nested_partials | 4.5KB | 2.4µs | 10.7µs | **14.2µs** | 3.6µs |
| bench_theme_cart_page | 12.6KB | 4.7µs | 22.6µs | **28.5µs** | 24.9µs |
| bench_theme_product_page | 17.2KB | 4.8µs | 32.1µs | **38.0µs** | 21.4µs |

Two optimization waves got here. The first (45–81µs cold, 18–37KB artifacts → ~30–40µs, 15–21KB) hoisted per-partial boilerplate into the (already-jitted) runtime, introduced a census-based inline-vs-shared-lambda policy for partials, baked error locations in as compile-time literals, and replaced the Marshal envelope with the framed binary. The second (the emitted-bytes tranches of [docs/win_all_scenarios.md](docs/win_all_scenarios.md)) compacted the compiled source before ISeq compilation, fused the dominant output patterns into single runtime sends (`raw+lookup+append` in one call), and merged appends across partial-inline seams via parse-time literal juxtaposition — another −15% artifact on the big pages.

All benchmarking runs through liquid-spec's harness (GC-disciplined timing, real percentiles, allocation counts). The adapter implements liquid-spec's **compiled-artifact protocol** (`LiquidSpec.dump_artifact` / `LiquidSpec.load_artifact`), so every bench reports the artifact stage — payload bytes, cold load, load+first-render, steady-state load time and allocations — with a dump → load → render roundtrip check per spec:

- `rake bench` (alias `rake scenarios`) — the three-scenario table (cache-miss / remote-hit / in-process + artifact size) vs reference liquid, geomean plus per-spec
- `rake bench:detail` — liquid-spec's detailed per-stage output (parse/render/load distributions, allocation counts, YJIT stats)
- `rake bench:partials` — the partial-heavy matrix in `specs/partials/` (a local liquid-spec suite; its `expected:` blocks are generated from the reference liquid gem)
- `rake bench:cold` — per-stage breakdown of the remote-hit load pipeline (envelope decode / `load_from_binary` / eval / first render), hard-validated against the reference gem
- `rake liquid_vm:scenarios` — the same three-scenario table including Shopify/liquid-vm classic and SSA; `rake liquid_vm:bench` for their detailed output. This private repo is cloned to `/tmp/liquid-vm` by default and skipped by all default tasks; see [docs/liquid_vm.md](docs/liquid_vm.md).

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

# 2) Artifact envelope (versioned + digest-checked; same format as to_artifact)
template.write_cache("greeting.ilc")
restored2 = LiquidIL::Template.load_cache("greeting.ilc")
restored2.render("name" => "World")
# => "Hello World"
```

Low-level direct call (no Template wrapper):

```ruby
iseq = RubyVM::InstructionSequence.load_from_binary(File.binread("greeting.iseq"))
proc_obj = iseq.eval
scope = LiquidIL::Scope.new({ "name" => "World" })
output = proc_obj.call(scope)
# => "Hello World"
```

Notes:
- ISeq binaries are Ruby-version specific (and generally architecture-specific).
- Prefer `write_cache`/`load_cache` (the framed artifact envelope) for persistence: it stamps the Ruby version and digest-checks the payload, so a stale or corrupt blob raises instead of being fed to `load_from_binary`.
- Use raw `write_iseq`/`load_iseq` only when you fully control the environment; error locations are compile-time literals either way — no source or metadata is needed at render time.

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
 IL (flat instruction array; structured IF/ELSE/END_IF markers for
     conditionals — labels + jumps exist only for loops)
    ↓
 Optimizer (on by default: one fused compacting peephole + const folding;
            the VM-era global analyses are permanently skipped)
    ↓
 Linker (resolve loop labels → indices; skipped when no loops)
    ↓
 Structured Compiler (IL → Ruby proc with native if/else/while)
    ↓
 Compact source → ISeq (statements fused before RubyVM compile)
```

### IL Instruction Set

The IL is a flat array of instructions, each a small Ruby Array. Conditionals are block-structured markers (always properly nested), not jumps — the backend never reconstructs control flow:

```ruby
[:WRITE_RAW, "Hello "]           # Emit literal text
[:FIND_VAR, "name"]              # Look up variable
[:CALL_FILTER, "upcase", 0, 3]   # Apply filter (line number rides along)
[:WRITE_VALUE]                   # Emit top of stack
[:IF, false]                     # Pop condition, begin then-block
[:ELSE]                          # (elsif desugars to ELSE + nested IF)
[:END_IF]                        # Close the conditional
[:FOR_INIT, "item", ...]         # Begin for loop (loops still use labels)
[:HALT]                          # End of template
```

### Optimization Passes

Optimization is on by default (`optimize: false` opts out for debugging). Most work happens in one fused, in-place compacting peephole scan — O(1) per fuse, no `delete_at` — plus targeted folding passes:

| Pass | Effect |
|------|--------|
| fold_const_ops | Constant comparisons/booleans; static `{% if true %}` branch elimination via the IF markers |
| fold_const_filters | `"hello" \| upcase` → `"HELLO"` at compile time |
| fused peephole | Const writes → raw text, raw-write merging, lookup-path collapse, redundant-IS_TRUTHY removal, constant propagation (with substitutions feeding the const folds in the same scan), `FIND_VAR+WRITE_VALUE` fusion |
| fold_const_captures | `capture x; "literal"; endcapture` → constant assign |
| remove_unreachable | Dead code after loop-back jumps |

Re-runs are conditional (a pass only re-runs when an earlier one changed something). The VM-era analyses (loop-invariant hoisting, lookup caching, value numbering) are permanently skipped: measured, they make the generated native Ruby *worse*. `FIND_VAR + LOOKUP_CONST_KEY` fusion happens at IL-emit time in the Builder, so that pattern never reaches the optimizer at all.

### Structured Compiler

The structured compiler converts IL to Ruby with native control flow:

- `if/else/end` emitted directly from the IF/ELSE/END_IF markers — a linear walk, no jump-target analysis
- Index-based `while` loops instead of FOR_INIT + FOR_NEXT dispatch
- Direct variable access instead of stack operations
- Partial bodies compiled once, then inlined or shared as lambdas by a per-template census
- The dominant output patterns collapse to single runtime sends (`_H.rolf(_O, "raw", obj, "key")` = raw text + lookup + append in one call — a helper send costs 63B of ISeq where the inline expansion costs 109B)
- The final source is compacted (comments/indentation dropped, statements fused, adjacent string literals juxtaposed) before `RubyVM::InstructionSequence` compilation

This produces code that YJIT can optimize effectively — no megamorphic dispatch, no interpreter loop, predictable branch shapes — while keeping the ISeq artifact small.

## Test Suite

```bash
# Run unit tests
bundle exec rake unit

# Run liquid-spec (5,181 specifications, including Shopify production
# recordings and the Shopify Theme Dawn suite — all passing)
bundle exec rake spec

# Run full suite (unit tests + liquid-spec)
bundle exec rake test

# Compare against reference Liquid implementation
bundle exec rake matrix
```

## Feature Coverage

Every template compiles — there is no interpreter fallback and no unsupported-template path (`can_compile?` is always true). Cases that historically needed special handling all work through the compiled path:

- **Dynamic partial names** — `{% include variable_name %}` compiles the partial at render time, cached per name across renders
- **Break/continue in included partials** — interrupts propagate out of `{% include %}` into the caller's loop
- **Recursive partials** — direct and mutual recursion resolve through the dynamic-partial path

The full liquid-spec suite (5,181 specs: core Liquid, lax mode, Shopify production recordings, Shopify Theme Dawn) passes, with output validated byte-for-byte against the reference `liquid` gem in every benchmark run. Remaining adapter opt-outs: `shopify_includes` and `shopify_error_handling` (Shopify-internal include quirks and production error formatting).
