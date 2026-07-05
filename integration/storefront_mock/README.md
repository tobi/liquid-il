# Storefront integration mock

A faithful miniature of the Shopify storefront renderer's integration substrate,
built entirely in-repo, proving the LiquidIL-as-a-third-engine design from
[`.goals/05-storefront-integration.md`](../../.goals/05-storefront-integration.md)
end to end — with the reference `liquid` gem as a byte-for-byte conformance
oracle. Nothing here touches the real storefront tree; every storefront
component is mocked.

Run it:

```
bundle exec ruby -Ilib test/storefront_mock_integration_test.rb
```

It is also part of `rake test` (registered in `TEST_FILES`).

## What it mirrors

| storefront thing | mock here |
|---|---|
| `Theme#assets_by_name` + content-addressed `theme_template_bodies` (shared across shops) | `MockTheme` + `BodyStore` (`lib/mock_theme.rb`) — name→digest **and name→bytesize** metadata with no body fetch; `load_body` counts every fetch |
| Sonic `CacheStore` two-tier memcached (node-local daemon → remote cluster) | `MockKeyValueStore` + `TieredStore` (`lib/mock_key_value_store.rb`) |
| `Liquid::Context` | `MockLiquidContext` (`lib/mock_liquid_context.rb`) — assigns, registers (`static`), environments, `handle_error`, `shop.features.enabled?` |
| `LiquidAdapter::Interface` | `AdapterInterface` (`lib/adapter_interface.rb`) |
| liquid-vm's `ContextShim` | `ScopeShim` (`lib/scope_shim.rb`) |
| `LiquidVmBytecodeCache`, generalized | `CompiledTemplateCache` + coders (`lib/compiled_template_cache.rb`) |
| in-process live-proc tier | `LiquidIL::TemplateCache` (from `lib/`) wired as the top tier |
| the inline/external partial census | `ThemePartialIndex` (compile-time, from metadata) + `RecordingFileSystem` (inline half) |
| lazy per-file partial loads | `CompiledTemplateCache#partial_provider` → LiquidIL's `registers["partial_provider"]` seam |
| `from_context` precedence | `AdapterRouter` (`lib/adapter_router.rb`) |
| the reference control engine | `LiquidRubyAdapter` over the `liquid` gem (`lib/liquid_ruby_adapter.rb`) |

## The cache key and the tiers

```
{slug}:{format_epoch}:{format_digest}:{RUBY_VERSION}-{RUBY_PLATFORM}:{composite_digest}:{vary_key}
```

`composite_digest` = entry-body digest **+ the digests of every INLINED
partial** — and *only* the inlined ones. Because the inlined-partial digests
are in the key, a small-snippet edit changes the key at *every* tier — the
live-proc tier included — so no tier can serve a stale artifact. RUBY_VERSION +
platform are in the key because ISeq binaries are not portable across Ruby
versions.

**The composite-key rule (inline vs external).** Which partials are inlined is
decided at compile time by a census with two halves:

- `ThemePartialIndex` (the **external** half) answers `digest(name)` and
  `bytesize(name)` from theme metadata alone — **no body fetch**. The LiquidIL
  compiler inlines a partial whose body is `<= INLINE_BODY_MAX_BYTES` (512B) and
  **externalizes** the larger ones (emitting a provider call site instead of an
  inlined body). A name the index doesn't know falls through to the file system
  unchanged.
- `RecordingFileSystem` (the **inline** half) fetches the bodies of the small
  partials the compiler decides to inline, counting each fetch.

The coder reads the split back from `Template#partial_dependencies` (the
compiler's authoritative disposition record) and folds **only the inline/lambda
digests** into `composite_digest`. **External-partial digests are deliberately
NOT in the entry key** — that is the whole point: an external partial is its own
content-addressed per-file artifact that versions *independently*, so editing a
large section recompiles *that section's* artifact and **leaves the entry
artifact (and its key) untouched**. See step (h).

The inlined-partial *name* set is a pure function of the entry body, stored as a
tiny "manifest" and memoized process-globally by entry digest, so a hot request
computes the composite key and serves the resident proc **without any KV read**.

Request layers, top to bottom (entries **and** external partials flow through
the same stack):

1. **live-proc tier** (`LiquidIL::TemplateCache`, process-global) — hot templates
   render from a resident proc; zero KV, no decode/ISeq-load.
2. **preloaded** — the previous request's touched-key fingerprint, warmed with a
   single `read_multi` (capped at 256), so a fresh process pays one batch fetch.
   External-partial artifact keys join the fingerprint (they are `@touched_keys`
   the moment a provider resolves one), so the batch warms **entry + partials**
   together.
3. **memoized** — this request's already-resolved keys.
4. **tiered store** — node-local → remote.
5. **compile** — cache miss: LiquidIL compiles the entry (small partials inlined
   via `RecordingFileSystem`, large ones externalized via `ThemePartialIndex`);
   the artifact is written to both KV tiers.

**External partials, resolved lazily.** The entry artifact carries a provider
call site (`_H.epc`) for each external partial. At render time
`CompiledTemplateCache#partial_provider` — parked on `registers["partial_provider"]`
by `AppProcess#render_request`, picked up by `Scope` — resolves each `(name)` to
its per-file artifact through the *same* five tiers. The provider keys on the
partial's **current** theme digest (not the digest baked into the caller), so an
edited body is picked up even when the entry is served from cache. A provider
miss compiles the partial from its theme body and writes the artifact back. The
provider is called **only when the call site actually executes** — a partial
behind a false condition is never asked for, never fetched, and gets no artifact.

The reference (control) engine is parameterized through the *same*
`CompiledTemplateCache` with a non-cacheable coder: it parses every request,
inlining every partial via its own file system. That it renders the *same*
bytes whether LiquidIL inlines or externalizes a partial is exactly what the
verifier gate proves.

## What the test proves (steps a–i)

- **(a) cold fleet** — request 1 compiles on miss, writes the artifact + manifest
  + fingerprint to KV, and fetches **only** the four bodies the layout tree
  references (laziness).
- **(b) remote-hit** — request 2, a *fresh process* over the same KV, batch-
  preloads via the fingerprint, does **zero compiles**, loads the artifact, and
  fetches **zero** bodies. Output identical to request 1 and to the reference.
- **(c) live-proc** — request 3, same process, hot: **zero KV reads**, served by
  the resident proc.
- **(d) theme edit** — one snippet body changes; only the affected entry's
  composite key changes; the next render recompiles exactly that unit while an
  entry that does not depend on the snippet still serves from cache.
- **(e) cross-shop sharing** — two "shops" on identical asset bodies map to the
  **same** cache key; shop B reuses shop A's compiled artifact with no recompile
  and no body fetch.
- **(f) verifier gate** — every request is rendered with BOTH engines and the
  outputs are asserted byte-identical, across several assign shapes (empty
  collections, blank values, missing keys). Mock templates use standard Liquid
  only, so this doubles as the conformance gate for the tag/filter surface.

Steps g–i drive the external-partial model. The entry references one **small**
partial (inlined) and two **large** partials (external), one of them behind a
runtime-falsy condition (`{% if show_mega %}`, never true — a *variable*, not the
literal `{% if false %}` the compiler would dead-code prune, so the external call
site is genuinely emitted). Every step keeps the both-engines diff byte-identical
and prints its timing.

- **(g) external laziness** — request 1 compiles the entry **without fetching the
  large bodies**: only the entry body, the inlined small body, and the *one* large
  partial that actually renders (`hero`) are fetched (fetch counter = 3). The
  large partial behind the false condition (`megafooter`) is **never fetched** and
  **no per-file artifact is written for it** — the provider is never asked because
  its call site never runs.
- **(h) partial edit** — editing the large `hero` body re-hashes it; the entry's
  **composite key is UNCHANGED** (external digests aren't in it). A fresh process
  serves the entry artifact from the store (**zero entry recompiles**), the
  provider sees the new `hero` digest, recompiles **only that partial** (fetching
  only the new body), and renders the new content. Old and new `hero` artifacts
  coexist under distinct keys; output parity with the reference holds.
- **(i) fingerprint warming covers partials** — request 2 in a fresh process warms
  **entry + external partials in one `read_multi`**: **zero compiles**, **zero
  partial compiles**, **zero body fetches**, output byte-identical to the
  reference.

Representative timings (Ruby 4.0, YJIT; µs, single local run — hardware-dependent):

| step | µs |
|---|---:|
| control parse+render (reference) | ~330 |
| cold compile+render (a) | ~340 |
| remote-hit load+render (b) | ~60 |
| live-proc render (c) | ~25 |
| cold external compile+render (g) | ~420 |
| partial edit, entry from cache (h) | ~240 |
| warm external (entry+partials) (i) | ~85 |

## Known limitation

`{% include %}` + `{% cycle %}` across the external boundary does **not** share
the caller's cycle state: an external partial invoked with `{% include %}` starts
its own cycle counters rather than continuing the caller's. The mock templates
therefore use `{% render %}` (isolated) for external partials and never pair an
external `{% include %}` with `{% cycle %}`. Small partials that need shared cycle
state stay inline (their bodies are baked into the entry artifact), where cycle
state flows normally.

## The one lib hook

The harness adds exactly one method to `lib/`: `CompiledArtifact#render_scope(scope)`
(`lib/liquid_il/template_cache.rb`) — render a loaded artifact against a
caller-supplied, fully-configured `Scope` instead of building one from assigns.
This is the ContextShim seam: the shim owns the engine `Scope`, and the engine
executes the artifact's proc against it. Error formatting matches `#render`. The
external-partial feature needed **no further lib changes**: `partial_index`,
`Template#partial_dependencies`, `registers["partial_provider"]`, `_H.epc`, the
`SEG_PARTIAL_DEPS` artifact segment, and
`CompiledArtifact#render_to_output_buffer` are all already-shipped LiquidIL APIs.
