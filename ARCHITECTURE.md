# LiquidIL Architecture

LiquidIL compiles a Liquid template once, persists a Ruby ISeq artifact, and
reuses the loaded compiled template for many renders with different assigns.
The production target is:

```text
compile once → persist artifact → load in another process → render repeatedly
```

Assigns are never part of compilation, cache identity, the literal pool, or the
artifact. Every render receives a fresh `Scope` built from that call's assigns.

## Actual pipeline

```text
Liquid source
  → TemplateLexer / ExpressionLexer
  → Parser + IL::Builder
  → semantic IL passes and label linking
  → RubyCompiler analysis and lowering
  → compact Ruby source
  → RubyVM::InstructionSequence binary
  → Artifact v2 envelope
  → CompiledArtifact
  → RenderExecutor + fresh Scope per render
```

There is no interpreter VM in the production path. The IL is a compiler IR;
Ruby/YJIT is the execution backend.

## 1. Lexing and parsing

`lib/liquid_il/lexer.rb` contains two lexers:

- `TemplateLexer` splits raw text, output expressions, and tags.
- `ExpressionLexer` tokenizes Liquid expressions using byte dispatch tables.

`lib/liquid_il/parser.rb` is a recursive-descent parser. It emits stack IL
directly through `IL::Builder`; there is no separate Liquid AST allocation.
Whitespace control, static partial names, source locations, and syntax policy are
resolved here whenever possible.

## 2. Intermediate language

`lib/liquid_il/il.rb` defines the instruction set as compact arrays:

```ruby
[IL::FIND_VAR_PATH, "product", ["title"]]
[IL::CALL_FILTER, "upcase", 0, source_line]
[IL::WRITE_VALUE]
```

The IL represents Liquid semantics independently of Ruby syntax. It includes:

- constants and variable/property reads
- output and assignment
- structured conditionals
- loops and interrupts
- captures, cycles, and `ifchanged`
- static/dynamic partial calls
- filter calls with source locations

`IL.link` resolves symbolic loop labels. `lib/liquid_il/compiler.rb` runs
semantic passes such as constant folding, write fusion, path collapse, dead-code
removal, and lookup census. Ruby-specific decisions do not belong in these
passes.

## 3. Ruby lowering

`lib/liquid_il/ruby_compiler.rb` lowers IL to native Ruby control flow and
expressions. Generated code is specialized for template structure, not render
input values.

### CodeFragment

`lib/liquid_il/ruby_compiler/code_fragment.rb` carries generated expression
source plus semantic metadata:

- known value category
- output policy (`direct`, `to_s`, or full Liquid conversion)
- error-marker propagation
- filter-cache metadata
- compiler-owned value origin

Output conversion, filter chaining, truthiness, helper inclusion, and loop-item
lookup decisions consume this metadata. They do not infer semantics by applying
regular expressions to generated Ruby.

### Effects

Nested emission frames record scope reads, dynamic access, open partial calls,
and `forloop`/`parentloop` use. Loop planning uses these effects to select a
fast path or the full scope-synchronizing fallback.

### Partials

Static partials have three dispositions:

- `inline`: compiled into the caller when structured IL analysis proves it safe
- `lambda`: compiled once inside the artifact and called by runtime helpers
- `external`: represented by name/digest and supplied by a `PartialProvider`

Bound isolated partials are lowered from IL against compiler-owned argument
locals. This avoids generated-source substitution while retaining a flat ISeq.
Any partial shape outside the explicit safe opcode set uses an isolated render
scope. Render-time argument values are rebuilt on every call and are never
persisted.

### Source serialization

Semantic output decisions happen in IL/codegen. `ProgramSerialization` removes
formatting and structurally coalesces adjacent compiler-owned `_O << …` statement
records before ISeq compilation. It never infers value types, scope behavior, or
filter semantics from generated expressions; those decisions come from
`CodeFragment` and effects metadata.

## 4. Compile-time constants

Large static raw literals can be moved out of the ISeq into the artifact's
immutable constants segment. The generated proc receives that constants array
alongside the fresh render scope:

```ruby
proc do |_S, _pc|
  _O << _pc[0]
  _H.oa(_O, _S.lookup("customer"))
end
```

`_pc` contains only compile-time template data. It never contains assigns,
registers, Drops, or values observed during rendering. Pooling starts at 1KB: measurements showed that decoding smaller pooled strings costs
more than the ISeq bytes it saves.

## 5. ISeq and compiler caches

Compiler caches use complete immutable String/Array keys. Ruby's built-in hash
provides the fast bucket lookup and equality checks make collisions harmless.
Cross-process content identity belongs to the host asset store/partial index,
which supplies its own persisted digest alongside each body.

Cache rules:

- Context compile keys include source, explicit parse options, and tag-registry
  generation.
- Partial keys include name, source, compiler ABI, context/filter/limit state,
  and partial-index identity.
- ISeq and IL-discovery caches retain complete immutable keys rather than using
  a bare `String#hash` value as identity.
- Every process-wide cache is bounded.
- Ruby `Hash` keys that retain full values still verify equality, so ordinary
  hash collisions cannot alias entries.

## 6. Artifact v2

`lib/liquid_il/artifact.rb` frames the persisted data with:

- format version
- exact Ruby version/patchlevel/platform stamp
- LiquidIL runtime and compiler ABI stamp
- CRC32 over the complete segment payload (the fastest stable checksum available in this Ruby build)
- ISeq length and framed segments

Known segments contain the ISeq, encoding-tagged immutable compile literals,
JSON-safe constants, and external partial dependency metadata. JSON is used instead of Marshal for v2
metadata so envelope decoding cannot instantiate arbitrary Ruby objects.
Legacy trusted Marshal cache payloads remain readable during migration.

An artifact contains executable ISeq. If an untrusted party can write the
remote cache, the host must authenticate the entire artifact (for example with
an HMAC) before calling `load_from_binary`.

## 7. Loading and rendering

`LiquidIL.load_artifact(blob)` returns a `CompiledArtifact`. The same instance
can render any number of times:

```ruby
compiled = LiquidIL.load_artifact(blob)
compiled.render("customer" => { "name" => "Ada" })
compiled.render("customer" => { "name" => "Grace" })
```

`lib/liquid_il/render_executor.rb` is the single invocation/error contract used
by both `Template` and `CompiledArtifact`. It:

1. builds a fresh `Scope` from the current assigns and render options,
2. installs registers, limits, filters, filesystem, and partial provider,
3. invokes the reusable compiled proc,
4. applies identical error formatting.

`TemplateCache` is a byte-bounded LRU for already-loaded artifacts. Its cache-hit
identity uses the checksum embedded in a validated v2 artifact, avoiding a second
full-blob pass.

## 8. Performance invariants

All changes are measured in four dimensions:

1. cache-miss compile + render
2. remote artifact load + first render (primary production workload)
3. in-process repeated render
4. artifact and ISeq bytes

The runtime library is assumed loaded and warm with YJIT enabled. Repeated
protocols belong in runtime helpers when a helper call does not materially hurt
warm render. Generated code stays specialized where that is required for the
hot path.

`rake bench:cold` measures both stage-level decode/ISeq/eval timing and the
public `load_and_render` path. It validates output against fresh compilation and
the reference Liquid gem before reporting results.
