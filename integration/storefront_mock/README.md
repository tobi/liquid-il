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
| `Theme#assets_by_name` + content-addressed `theme_template_bodies` (shared across shops) | `MockTheme` + `BodyStore` (`lib/mock_theme.rb`) — name→digest metadata with no body fetch; `load_body` counts every fetch |
| Sonic `CacheStore` two-tier memcached (node-local daemon → remote cluster) | `MockKeyValueStore` + `TieredStore` (`lib/mock_key_value_store.rb`) |
| `Liquid::Context` | `MockLiquidContext` (`lib/mock_liquid_context.rb`) — assigns, registers (`static`), environments, `handle_error`, `shop.features.enabled?` |
| `LiquidAdapter::Interface` | `AdapterInterface` (`lib/adapter_interface.rb`) |
| liquid-vm's `ContextShim` | `ScopeShim` (`lib/scope_shim.rb`) |
| `LiquidVmBytecodeCache`, generalized | `CompiledTemplateCache` + coders (`lib/compiled_template_cache.rb`) |
| in-process live-proc tier | `LiquidIL::TemplateCache` (from `lib/`) wired as the top tier |
| `from_context` precedence | `AdapterRouter` (`lib/adapter_router.rb`) |
| the reference control engine | `LiquidRubyAdapter` over the `liquid` gem (`lib/liquid_ruby_adapter.rb`) |

## The cache key and the tiers

```
{slug}:{format_epoch}:{format_digest}:{RUBY_VERSION}-{RUBY_PLATFORM}:{composite_digest}:{vary_key}
```

`composite_digest` = entry-body digest **+ the digests of every inlined
partial** (the goal doc's composite key). Because the inlined-partial digests
are in the key, a partial-body edit changes the key at *every* tier — the
live-proc tier included — so no tier can serve a stale artifact. RUBY_VERSION +
platform are in the key because ISeq binaries are not portable across Ruby
versions.

The inlined-partial *name* set is a pure function of the entry body, stored as a
tiny "manifest" and memoized process-globally by entry digest, so a hot request
computes the composite key and serves the resident proc **without any KV read**.

Request layers, top to bottom:

1. **live-proc tier** (`LiquidIL::TemplateCache`, process-global) — hot templates
   render from a resident proc; zero KV, no decode/ISeq-load.
2. **preloaded** — the previous request's touched-key fingerprint, warmed with a
   single `read_multi` (capped at 256), so a fresh process pays one batch fetch.
3. **memoized** — this request's already-resolved keys.
4. **tiered store** — node-local → remote.
5. **compile** — cache miss: LiquidIL compiles the entry with partials inlined
   via a body-fetching, dep-recording file system; the artifact is written to
   both KV tiers.

The reference (control) engine is parameterized through the *same*
`CompiledTemplateCache` with a non-cacheable coder: it parses every request,
which is the honest comparison (the `liquid` gem ships no bytecode cache).

## What the test proves (steps a–f)

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

Representative timings (Ruby 4.0, YJIT; µs, single local run):

| step | µs |
|---|---:|
| control parse+render (reference) | ~2400 |
| cold compile+render (a) | ~7700 |
| remote-hit load+render (b) | ~650 |
| live-proc render (c) | ~90 |

## TODO seams for the external-partials branch

The in-flight `partial_index` / `PartialProvider` / `render_to_output_buffer`
work slots in at clearly-marked seams; v1 is built against today's LiquidIL API
(whole-template artifacts, partials inlined via `file_system`):

- `RecordingFileSystem` (`lib/compiled_template_cache.rb`) is the **inline** half
  of the census. When the compiler accepts a digest index + `PartialProvider`,
  large/shared partials become EXTERNAL: their own per-file artifacts, loaded
  lazily and warmed by the fingerprint preloader, with a provider call site
  emitted instead of an inlined body. The composite-key discipline already
  models the inline dependency-digest folding that split requires.
- `IlRenderableTemplate#render_to_output_buffer` (`lib/liquid_il_adapter.rb`)
  currently appends the rendered String; swap for native
  `CompiledArtifact#render_to_output_buffer(scope, output)` that appends into the
  caller's preallocated 16KB buffer.

## The one lib hook

The harness adds exactly one method to `lib/`: `CompiledArtifact#render_scope(scope)`
(`lib/liquid_il/template_cache.rb`) — render a loaded artifact against a
caller-supplied, fully-configured `Scope` instead of building one from assigns.
This is the ContextShim seam: the shim owns the engine `Scope`, and the engine
executes the artifact's proc against it. Error formatting matches `#render`.
