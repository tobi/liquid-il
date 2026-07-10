# LiquidIL

LiquidIL is a Ruby library for compiling [Liquid](https://shopify.github.io/liquid/) templates to optimized Ruby bytecode. It parses Liquid into a compact intermediate language (IL), applies semantic optimizations, and lowers the result to Ruby that CRuby and YJIT can execute without an interpreter loop.

```ruby
require "liquid_il"

LiquidIL.render("Hello {{ name | upcase }}!", "name" => "Ada")
# => "Hello ADA!"
```

LiquidIL is designed for applications that compile a template once, persist the compiled artifact, and load it in another process:

```text
Liquid source → IL → optimized Ruby → Ruby ISeq → persisted artifact
                                                   ↓
remote cache → artifact bytes → loaded callable → render
```

## Requirements

- CRuby 3.1 or newer
- Ruby 4.x with YJIT is the primary performance target
- A JIT is recommended but not required for correctness

Compiled artifacts contain CRuby instruction sequences. They are tied to the exact Ruby version, patchlevel, platform, and LiquidIL compiler/runtime ABI that produced them.

## Installation

Add the gem to your bundle:

```bash
bundle add liquid-il
```

Or in a `Gemfile`:

```ruby
gem "liquid-il"
```

Then load the library with:

```ruby
require "liquid_il"
```

## Basic usage

### Render once

```ruby
output = LiquidIL.render(
  "Hello {{ customer.name }}!",
  "customer" => { "name" => "Ada" }
)

output # => "Hello Ada!"
```

String and symbol keys are accepted in assigns. Liquid variable names are normalized to strings.

### Compile once and render repeatedly

```ruby
template = LiquidIL.parse("{{ greeting }}, {{ name }}!")

template.render("greeting" => "Hello", "name" => "Ada")
# => "Hello, Ada!"

template.render(greeting: "Welcome", name: "Grace")
# => "Welcome, Grace!"
```

A compiled `Template` can be reused. Each render gets fresh scope, output, cycle, capture, counter, and loop state.

## Production API: `Renderer` and `RenderSession`

For an application with named templates and memcache, this is the predominant API. Create one `Renderer` per process and one session per request:

```ruby
require "dalli"
require "liquid_il"

RENDERER = LiquidIL::Renderer.new(
  remote_cache: Dalli::Client.new("memcache.internal:11211"),
  max_local_bytes: 64 * 1024 * 1024,
  # Change this when host filters, source-resolution rules, or deployment code
  # that affects rendering changes. Ruby and LiquidIL ABI stamps are added too.
  namespace: "storefront:#{ENV.fetch('RELEASE_SHA')}",
  instrumenter: ->(event, payload) {
    Metrics.emit(event, payload)
  }
)

html = RENDERER.session(
  templates: theme.templates,
  preload_key: "shop:#{shop.id}:route:product"
) do |render|
  render.render(
    "layout/theme",
    assigns,
    registers: { request_id: request.id }
  )
end
```

`Renderer` owns process-wide state and is thread-safe. `RenderSession` owns request memoization, touched keys, the external-partial provider, and per-request statistics; do not share a session between threads. The block form always closes the session and writes its bounded preload fingerprint, even when rendering raises.

### Template source protocol

`templates:` is a lightweight metadata/body lookup:

```ruby
class ThemeTemplates
  def initialize(asset_index, body_store)
    @asset_index = asset_index # name => { digest:, bytesize: }
    @body_store = body_store   # content-addressed bodies
  end

  # These two calls must not fetch the body.
  def digest(name) = @asset_index[name]&.fetch(:digest)
  def bytesize(name) = @asset_index[name]&.fetch(:bytesize)

  # Called only when compilation is actually required.
  def read(name)
    asset = @asset_index.fetch(name)
    @body_store.fetch(asset.fetch(:digest))
  end
end
```

`read_template_file(name, context = nil)` may be used instead of `read`. A source can also implement `canonical_name(name)`, `external?(name)`, or `inline?(name)` when the host has an authoritative partition policy.

### Cache lookup order

Every named entry and every lazily executed external partial uses the same path:

1. request memo
2. process-local loaded-proc LRU
3. lazily loaded batch preload for the request shape
4. remote cache (`Rails.cache`-style `read/write/read_multi` or Dalli-style `get/set/get_multi`)
5. source read and compilation

The preload record is only a performance hint, never an invalidation authority. It is not fetched when the loaded-proc LRU can satisfy the request, so a hot render performs no remote-cache operation. On a fresh process, one multi-get can warm the entry, its dependency plan, and the external partials touched by the previous request.

Remote records are published artifact-first and head-pointer-second. Corrupt, stale, missing, or ABI-incompatible records become cache misses and are rebuilt from source. Process-local striped singleflight suppresses duplicate compilation without making correctness depend on locking across machines.

### Partial compilation policy

Static partials are planned automatically, with no per-request tuning switch:

- Small partials are compiled into the caller as inline code or a shared lambda. Their current digests are part of the caller's artifact identity, so editing one invalidates the caller.
- Large or source-opaque partials are emitted as external call sites. They have independent content-addressed artifacts and are looked up only if the call site executes. Editing one does not invalidate its caller.
- Crossing the inline/external boundary invalidates and replans the caller.
- Nested static partials follow the same rules transitively.
- Dynamic partial names resolve at render time.

A dependency plan sidecar lets a remote hit compute and validate the exact artifact key using only `digest`/`bytesize` metadata. Template bodies are not fetched on local or remote hits. Source identities are rechecked around compilation; a moving source is retried and never published under a stale key.

### Individual lookup and prewarming

A session can fetch one named template explicitly. The returned object remains bound to the session's external-partial provider:

```ruby
RENDERER.session(templates: theme.templates) do |render|
  product = render.fetch("templates/product")
  product.render(assigns)
end
```

Use `render.render(...)` for the common path. A fetched template should not outlive its session.

### Statistics and instrumentation

```ruby
session = RENDERER.session(templates: theme.templates)
output = session.render("layout/theme", assigns)
pp session.stats
session.close
```

Stats include request/local/preload/remote hits and misses, source metadata/body lookups, compile count, invalid plans/artifacts, bytes written, preload width, and renders. The instrumenter receives events such as:

- `liquid_il.cache.lookup`
- `liquid_il.cache.write`
- `liquid_il.cache.preload`
- `liquid_il.source.lookup`
- `liquid_il.compile`
- `liquid_il.render`
- `liquid_il.artifact.invalid`
- `liquid_il.session.start` / `liquid_il.session.finish`

An object responding to `instrument`, including `ActiveSupport::Notifications`, can be passed directly instead of a callable.

### Buffered output

```ruby
buffer = +"<main>"

RENDERER.session(templates: theme.templates) do |render|
  render.render_to_output_buffer(
    "snippets/greeting",
    { "name" => "Ada" },
    buffer
  )
end
# => "<main>Hello Ada"
```

The method returns the supplied buffer. The lower-level `Template` and `CompiledArtifact` objects expose the same `render_to_output_buffer` shape.

## Lower-level compilation with `Context`

`Renderer` is the recommended named-template and cache API. Use `LiquidIL::Context` directly for uncached compilation, tooling, standalone exports, or applications that provide their own artifact-cache coordinator.

```ruby
context = LiquidIL::Context.new(
  file_system: MyFileSystem.new,
  registers: { request_id: "abc-123" },
  strict_variables: true,
  strict_filters: true,
  error_mode: :strict2,
  resource_limits: {
    output_limit: 1_000_000,
    render_score_limit: 100_000
  }
)

template = context.parse("{% render 'card', product: product %}")
output = template.render("product" => product)
```

`Context#parse` keeps a bounded per-context compilation cache. Call `context.clear_cache` after changing application configuration that LiquidIL cannot observe directly.

### Parse modes

`error_mode:` controls parser behavior:

- `:lax` — accept Liquid's permissive syntax where supported
- `:warn` — continue and collect parser warnings
- `:strict` — reject invalid syntax
- `:strict2` — the strictest supported parser behavior

### Render errors

By default, Liquid runtime errors are rendered inline, matching Liquid's normal storefront behavior:

```ruby
template.render(assigns)
```

Use `render!` to raise instead:

```ruby
template.render!(assigns)
# may raise LiquidIL::RuntimeError,
# LiquidIL::UndefinedVariable, LiquidIL::UndefinedFilter, etc.
```

Strictness can also be overridden for one render:

```ruby
template.render!(
  assigns,
  strict_variables: true,
  strict_filters: true
)
```

## Partials

A file system may implement either `read_template_file(name, context = nil)` or `read(name)`. The Liquid-compatible form is recommended:

```ruby
class MemoryFileSystem
  def initialize(files)
    @files = files
  end

  def read_template_file(name, _context = nil)
    @files.fetch(name.to_s)
  end
end

context = LiquidIL::Context.new(
  file_system: MemoryFileSystem.new(
    "product_card" => "<article>{{ product.title }}</article>"
  )
)

template = context.parse("{% render 'product_card', product: product %}")
template.render("product" => { "title" => "Snowboard" })
# => "<article>Snowboard</article>"
```

Static partials are analyzed at compile time and may be inlined or emitted once as shared lambdas. Dynamic names, recursive partials, `include`, and `render ... for` remain supported.

For large template stores, a host can externalize partial artifacts and resolve them through `partial_index:` and the render-time `partial_provider:` API. See [ARCHITECTURE.md](ARCHITECTURE.md) and the storefront integration in [`integration/storefront_mock/`](integration/storefront_mock/).

## Custom filters

Register filters on one context:

```ruby
module MoneyFilters
  def money(input, currency = "USD")
    format("%.2f %s", input.to_f, currency)
  end
end

context = LiquidIL::Context.new
context.register_filter(MoneyFilters)

context.render("{{ price | money: 'CAD' }}", "price" => 12.5)
# => "12.50 CAD"
```

A pure filter cannot access render scope and can use direct compiled dispatch:

```ruby
module MathFilters
  def double(input)
    input.to_f * 2
  end
end

context.register_filter(MathFilters, pure: true)
```

Register globally for subsequently created contexts:

```ruby
LiquidIL.register_filter(MoneyFilters)
```

Custom tags, filter purity, strict modes, registers, and the Drop protocol are documented in [EXTENSIBILITY.md](EXTENSIBILITY.md).

## Safe objects and Drops

Template property lookup does not expose arbitrary Ruby methods. Use hashes, supported scalar/collection values, `to_liquid`, `LiquidIL::Drop`, or compatible `Liquid::Drop` subclasses.

```ruby
class ProductDrop < LiquidIL::Drop
  def initialize(product)
    @product = product
  end

  def title = @product.title
  def price = @product.price
end

template = LiquidIL.parse("{{ product.title }} — {{ product.price }}")
template.render("product" => ProductDrop.new(product))
```

Only the intended Drop surface is visible to templates. Methods inherited from `Object` and `Kernel`, including reflective dispatch, are blocked.

## Persisting compiled templates

`Renderer` manages these details automatically. The APIs below are the lower-level persistence primitives for hosts that need a custom cache coordinator.

### Framed artifacts

`Template#to_artifact` returns a binary `String` suitable for memcache, a database, or an object store:

```ruby
source = "Hello {{ name }}"
template = LiquidIL.parse(source)
artifact_bytes = template.to_artifact

cache.set("templates/greeting", artifact_bytes)
```

Load and render in another process:

```ruby
bytes = cache.get("templates/greeting")
compiled = LiquidIL.load_artifact(bytes)

compiled.render("name" => "Ada")
# => "Hello Ada"
```

For a one-shot cold load:

```ruby
LiquidIL.load_and_render(bytes, "name" => "Ada")
```

The artifact envelope contains:

- an exact Ruby version/patchlevel/platform stamp
- LiquidIL compiler and runtime ABI stamps
- a CRC32 over the complete payload
- the ISeq binary
- immutable compile-time constants and external partial metadata, when needed

It does **not** embed the Liquid source or render assigns.

Handle stale and damaged entries by recompiling from source:

```ruby
begin
  compiled = LiquidIL.load_artifact(cache.get(key))
rescue LiquidIL::StaleArtifactError, LiquidIL::CorruptArtifactError
  template = LiquidIL.parse(source)
  bytes = template.to_artifact
  cache.set(key, bytes)
  compiled = LiquidIL.load_artifact(bytes)
end
```

Artifacts contain executable code. If an untrusted party can write to the cache, authenticate the complete artifact before loading it.

### Loaded-template LRU

`Renderer` already owns a `TemplateCache`. When building a custom coordinator, `TemplateCache` avoids repeatedly loading popular artifacts and enforces a byte budget:

```ruby
cache = LiquidIL::TemplateCache.new(max_bytes: 64 * 1024 * 1024)

compiled = cache.fetch(template_key) { memcache.get(template_key) }
compiled.render(assigns)

# Or load/reuse and render in one call:
cache.render(template_key, artifact_bytes, assigns)
```

Republishing different artifact bytes under the same key automatically invalidates the loaded entry. Oversized single artifacts are rendered but not retained.

### Files and lower-level formats

```ruby
template.write_cache("template.ilc")
restored = LiquidIL::Template.load_cache("template.ilc")

# Raw, unframed Ruby ISeq; only use in a fully controlled environment.
template.write_iseq("template.iseq")
raw = LiquidIL::Template.load_iseq("template.iseq")
```

See [docs/compiled_templates.md](docs/compiled_templates.md) for the lower-level APIs and caveats.

## Standalone generated Ruby

LiquidIL can export a compiled template as a Ruby module. The generated file still uses `liquid_il` runtime helpers.

```ruby
template = LiquidIL.parse("Hello {{ name | upcase }}!")

template.write_ruby("greeting.rb", module_name: "Greeting")

require_relative "greeting"
Greeting.render("name" => "Ada")
# => "Hello ADA!"
```

Use `to_ruby("Greeting")` to get the source as a string.

## Concurrency

A `Template` or `CompiledArtifact` can be shared by Ruby threads. Rendering is lock-free and creates request-local execution state for every call. Compilation caches are separately bounded and mutex-protected.

ISeq-backed procs are not shareable across Ractors. Share frozen artifact bytes and load them inside each Ractor:

```ruby
bytes = LiquidIL.parse("Hello {{ name }}").to_artifact.freeze
Ractor.make_shareable(bytes)

worker = Ractor.new(bytes) do |artifact|
  require "liquid_il"
  LiquidIL.load_artifact(artifact).render("name" => "Ada")
end

worker.value # => "Hello Ada"
```

Static artifacts are supported in this shape. Dynamic partial compilation still depends on process-local compiler and file-system state.

## CLI

The repository includes `bin/liquidil` for inspection and debugging:

```bash
bin/liquidil render "Hello {{ name }}" -e name=Ada
bin/liquidil parse "{% for i in (1..3) %}{{ i }}{% endfor %}"
bin/liquidil compile "{{ value | upcase }}"
bin/liquidil eval "{{ x | plus: y }}" -e x=2 -e y=3
bin/liquidil passes
```

## How compilation works

```text
Liquid source
  → TemplateLexer / ExpressionLexer
  → Parser + IL builder
  → semantic optimization and label linking
  → structured Ruby lowering
  → compact Ruby source
  → RubyVM::InstructionSequence
  → optional artifact envelope
```

The generated code uses native Ruby control flow and shared runtime helpers rather than interpreting an AST or dispatching a Liquid bytecode loop. Compiler decisions are carried by typed code fragments and effect metadata; generated Ruby strings are not re-parsed to recover semantics.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete pipeline and [docs/win_all_scenarios.md](docs/win_all_scenarios.md) for current performance work.

## Benchmarks

### Methodology

The benchmark suite is provided by [Shopify/liquid-spec](https://github.com/Shopify/liquid-spec). LiquidIL is pinned to liquid-spec commit `c4c7931` for the results below.

The current harness measures three distinct workflows:

1. **Source → first render** — compile and render as one atomic sample.
2. **Artifact → first render** — load persisted bytes and render as one atomic sample.
3. **Resident render** — repeatedly render a template already loaded in the adapter process.

The two atomic workflows run in the same warmed adapter process. Liquid-spec takes 10 samples of each and interleaves their order to reduce ordering bias. This deliberately measures application-level compile/load workflows without process-fork noise; it is not a process-start benchmark.

Resident measurements use operation batches with normal GC policy. Assign preparation happens outside the timer. Raw batches and workflow samples are retained as integer nanoseconds, and JSONL output preserves floating-point precision without rounding. Environment setup, JSON generation, parsing, and transport therefore do not contribute to the timed values.

`rake bench` also validates every requested adapter process, every benchmark result, the same-process workflow metadata and freshness fields, and the artifact roundtrip before printing a table. A missing or crashed adapter fails the task instead of silently shrinking the comparison.

### Latest results

Run on **2026-07-10** with Ruby **4.0.5**, YJIT, Linux x86-64, and an AMD Ryzen Threadripper PRO 7975WX. Values are geometric means across all 10 common benchmark templates; lower is better.

| adapter | source → first render | artifact → first render | resident render | artifact payload |
|---|---:|---:|---:|---:|
| **LiquidIL** | 863µs | **269µs** | **52µs** | 9.0KB |
| liquid_ruby | **419µs** | — | 155µs | — |
| liquid_vm classic | 1.75ms | 297µs | 190µs | **2.3KB** |
| liquid_vm SSA | 2.77ms | 328µs | 279µs | 2.4KB |

Reference Liquid does not expose liquid-spec's persistent compiled-artifact protocol, so it has no artifact lane. For liquid-vm, LiquidIL's optional adapter serializes both the root bytecode and the exact precompiled partial bytecode produced by the normal VM compile path; load timing therefore measures deserialization, not source recompilation. Serialization runs only in liquid-spec's dump hook, outside the timed source and artifact-load workflows—no post-hoc timing subtraction is used. The adapter also isolates per-render register state so cycle counters cannot leak between validation renders.

On the geomean, LiquidIL has the fastest artifact-to-first-render and resident-render lanes: resident rendering is about **3.0× faster than Liquid**, **3.7× faster than liquid-vm classic**, and **5.4× faster than SSA**. LiquidIL's source workflow beats both VM modes but remains slower than reference Liquid. Its persisted artifact is about **3.9× larger** than liquid-vm classic's compact bytecode.

Full per-template results from the same run:

| benchmark | LiquidIL source → first | liquid_ruby source → first | LiquidIL artifact → first | LiquidIL resident | liquid_ruby resident | payload |
|---|---:|---:|---:|---:|---:|---:|
| dynamic_partials | **157µs** | 162µs | 185µs | **48µs** | 107µs | 1.5KB |
| liquid_tag_inventory_report | 2.77ms | **592µs** | 2.32ms | **55µs** | 286µs | 5.2KB |
| liquid_tag_leaderboard | 910µs | **342µs** | 489µs | **83µs** | 174µs | 4.9KB |
| storefront_product_page | 2.27ms | **1.11ms** | 670µs | **142µs** | 394µs | 33.1KB |
| storefront_collection_page | 2.30ms | **962µs** | 1.03ms | **171µs** | 393µs | 23.3KB |
| storefront_cart_page | 1.62ms | **525µs** | 110µs | **45µs** | 145µs | 15.6KB |
| storefront_order_email | 945µs | **503µs** | 110µs | **42µs** | 96µs | 13.3KB |
| storefront_cms_page | 302µs | **224µs** | 91µs | **60µs** | 162µs | 4.5KB |
| shopify_theme_full_page | 293µs | **188µs** | 26µs | **7µs** | 31µs | 6.7KB |
| shopify_theme_product_page | 815µs | **428µs** | 484µs | **34µs** | 137µs | 18.0KB |

`rake liquid_vm:scenarios` prints all four adapters for every template, validates every artifact roundtrip, and writes the raw rows to `tmp/liquid_vm_scenarios.jsonl`.

These numbers are not comparable to older README tables that added separately measured parse, load, and warm-render means, nor to the briefly used fork-isolated workflow. The current source and artifact columns are atomic, same-process workflow samples.

Run the benchmark locally:

```bash
bundle exec rake bench                 # source/artifact/resident table vs Liquid
bundle exec rake bench:detail          # distributions, allocations, raw batches, YJIT stats
bundle exec rake bench:partials        # local partial-heavy suite
bundle exec rake bench:cold            # LiquidIL-specific artifact stage breakdown
bundle exec rake bench:threads         # loaded-template thread throughput
bundle exec rake liquid_vm:scenarios   # optional liquid-vm classic + SSA comparison
```

Shopify/liquid-vm is private and optional. Setup and environment variables are documented in [docs/liquid_vm.md](docs/liquid_vm.md).

## Tests

```bash
bundle exec rake unit    # Ruby unit and integration tests
bundle exec rake spec    # complete liquid-spec suite
bundle exec rake test    # unit tests + liquid-spec
bundle exec rake matrix  # differential matrix against reference Liquid
```

Focused liquid-spec commands:

```bash
bundle exec liquid-spec run spec/liquid_il.rb -n "for"
bundle exec liquid-spec eval spec/liquid_il.rb -l "{{ 'hi' | upcase }}"
```

Every supported template goes through the compiled path; there is no interpreter fallback. The adapter currently opts out of Shopify-internal include behavior and Shopify production error formatting.

## Project status

LiquidIL is an experimental `0.1.x` library. `Renderer`/`RenderSession` is the recommended production API; `Context`, artifacts, and `TemplateCache` remain available as composable lower-level primitives. Artifact ABI compatibility is intentionally strict and may change between releases. Persist source alongside cache identity so stale artifacts can always be rebuilt.

## License

MIT
