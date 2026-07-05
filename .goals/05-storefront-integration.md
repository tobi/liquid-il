# Goal 5: Storefront integration — LiquidIL as a third SFR engine

## Objective

Wire LiquidIL into the Shopify storefront renderer
(`~/world/trees/root/src/areas/core/storefront`) as a third engine beside
liquid-vm (the production default) and liquid-ruby, reusing every cache that
gets templates and partials to the renderer quickly, and prove it **out of
band on verifier replay traffic before any buyer request ever touches it**.

All storefront facts below were scouted 2026-07-05 with file:line pointers;
re-verify anchors by grep, not line number. Note: liquid-vm's serialization
constant is literally `Liquid::Vm::Sfr::LIQUID_IL_COMBINED_VERSION` — "Liquid
IL" in SFR code refers to liquid-vm's format, not this project. Naming will
collide; pick the slug `liquid-il` but expect to disambiguate internally.

## The seam (all of it)

- **Adapter registry**: `app/liquid/liquid_adapter.rb` — `from_context`
  precedence: forced (self-verify header or `FORCED_LIQUID_ADAPTER` env) →
  profiling cohort → default `liquid-vm, cohort: "enabled"`. No per-shop flag
  gates adapter choice today.
- **Contract**: `app/liquid/liquid_adapter/interface.rb`. `parse_raw` may
  return ANY object responding to `render(context)`, `render!(context)`,
  `render_to_output_buffer(context, output)` (see
  `renderable_template.rb`) — nothing else is assumed. Plus
  `eval_infallible_raw`, `new_parse_context_raw`, `filtering?`,
  `disable_native_filters!`, `set_native_feature_flag`, `wrap_context`.
- **Context bridging precedent**: liquid-vm's `ContextShim`
  (gem `lib/liquid/vm/hacks/context_shim.rb`): `method_missing` delegates
  everything to the wrapped `Liquid::Context` (assigns, registers,
  error surface stays Ruby); scope stack / variable storage / resource
  accounting / interrupt flag route to an engine-state object stashed at
  `registers.static[:liquid_vm_state]`; `handle_error` deliberately stays on
  the Ruby context; `new_isolated_subcontext` spawns a sub-shim per partial;
  strainer's `@context` is rebound to the shim so Ruby filters see it.
- **Filters/tags are engine-agnostic**: registered once on
  `Liquid::Environment.default` (`config/initializers/liquid/100_filters.rb`,
  `100_tags.rb`) as plain Ruby modules/classes; both adapters call them back
  through the strainer. Only the `link_to*` family has a native fast path,
  gated per-shop by `f_liquid_vm_native_link_to_filter`.
- **Compiled cache precedent**: `app/services/liquid_vm_bytecode_cache.rb` —
  per-FILE artifacts keyed
  `prefix(GLOBAL_BUST + PACK_DIGEST):content_digest:vary_key(blake3 of parse
  opts)`, stored in the two-tier memcached `application_cache` (10-day TTL,
  node-local daemon → remote cluster), request layers preloaded (fingerprint
  key-list `read_multi`, `MAX_PRELOAD_KEYS = 256`) → memoized → fetch.
  Invalidation is purely content-addressed. Canary+verification suppresses
  WRITES only; reads share the production cache.
- **Template supply**: theme asset metadata (name→cityhash) preloaded per
  theme per request (`Theme#assets_by_name`); bodies content-addressed in
  `theme_template_bodies`, **shared across shops** (`cache_by_shop_id:
  false`), Snappy-compressed, fetched lazily per asset with a
  previous-request fingerprint bulk prefetch
  (`Theme.preload_previously_used_template_bodies`).
- **Verifier**: 1% of prod requests recorded to Monorail
  (`VerifierMiddleware`), replayed by the external `Shopify/sfr-verifier`
  service; replays carry `X-Storefront-Verification-Request` and — key fact,
  documented in `docs/content/performance/perf_experiments.md` — the
  verifier ALREADY sets `X-SFR-Self-Verify-Features` on its replays to force
  flag state. `forced_liquid_adapter` consumes that same header for engine
  forcing, tagging cohort `"verifier"`. Diffs are raw response-body text
  diffs stored in GCS (`bin/show_verifier_diff`).
- **Runtime**: Ruby 4.0.2, YJIT enabled post-fork (ZJIT wired but off) —
  exactly LiquidIL's assumed environment. Error mode per request:
  `strict2` (`f_rigid_liquid_rendering`) or `lax` — exactly LiquidIL's
  implemented matrix. Global resource limits configured — LiquidIL compiles
  limit checks in only when configured, same shape. Render output goes into
  a 16KB preallocated String buffer via `render_to_output_buffer`.

## Architecture decision

Two ideas were considered and they are STAGES, not alternatives:

**A. The engine-agnostic compiled-template layer ("the wrappier thing").**
Generalize `LiquidVmBytecodeCache` into a `CompiledTemplateCache`
parameterized by engine: `(slug, format_digest, coder)` — liquid-vm's cache
becomes one instantiation; LiquidIL's is another whose coder is the framed
artifact (`Artifact.encode/decode`) and whose vary_key ADDITIONALLY includes
`RUBY_VERSION` + platform (ISeq binaries are not portable across Ruby
versions; the envelope already stamps this — the cache key must too, or
mixed-version fleets poison each other during Ruby upgrades). Keep per-FILE
artifact granularity to inherit, unchanged: cross-shop sharing (content-
addressed bodies), natural invalidation, the fingerprint preloader, and the
node-local tier.

**B. Verifier-first rollout (ship dark, learn out of band).** Because the
replay service already forces per-request features via the self-verify
header, a LiquidIL adapter that exists ONLY in the forced chain (no cohort,
no default path) is reachable exclusively by: internal folks with the VPN
header, and sfr-verifier replays configured to send
`X-SFR-Self-Verify-Features: liquid-il`. That yields production-truthful
output diffs (the GCS body diff = our differential fuzzer at production
scale), real cache-key distributions, hit rates, and latency histograms
(cohort `"verifier"` is already a stats dimension) with ZERO buyer
exposure. One infra check required: confirm sfr-verifier's replay traffic
passes the `shopifolk?` gate (`request.rb` — VPN header) — strongly implied
by the documented flag-forcing behavior but not verifiable from this tree.

Then, and only then: per-shop percentage rollout via the codebase's enforced
idiom `shop.features.enabled?("f_liquid_il_rendering")` (custom cops REQUIRE
this form) inserted before the `from_context` fallthrough.

## Work plan

### Phase 0 — LiquidIL-side prerequisites (this repo)

1. **Fix `artifact_self_consistency`** (fuzz/findings/artifact_self_consistency/):
   templates using render/include break when rendered from a LOADED artifact
   ("This liquid context does not allow includes"). This is literally the
   production path; nothing ships before it's fixed and covered by
   `rake bench:cold`-style roundtrip specs for partial-bearing templates.
2. **External partial references (the lazy-partial model).** New compile
   mode: the compiler receives, instead of (or alongside) a body-fetching
   file_system, a **digest index** (name → content_digest, available at
   compile time from `assets_by_name` without any body fetch) and a
   **PartialProvider** render-time interface (`call(name, digest) →
   callable`). Census decides per partial:
   - small & static → INLINE (fetch that body at compile time; the entry
     artifact's cache key becomes composite:
     `entry_digest + sorted inlined-partial digests` — deps tracking exists,
     grep `partial_cache_deps_valid?`);
   - large or shared → EXTERNAL: emit a provider call site; the partial is
     its own per-file artifact, loaded lazily on first use and warmed by the
     fingerprint preloader. The dynamic-partial machinery
     (`execute_dynamic_partial` + per-name caching) is the starting point;
     the artifact format's partial segment exists.
   Acceptance: a template with N static partials compiles WITHOUT fetching
   the bodies of external ones; render with a cold provider fetches lazily;
   `bench:cold` extended to validate the split.
3. **`render_to_output_buffer(context, output)`** native support on
   Template/loaded artifacts (append into a caller-provided buffer instead
   of allocating `_O` — the emitted proc already takes the buffer implicitly;
   thread it through the entry point).

### Phase 1 — the adapter (storefront repo)

4. `LiquidAdapter::LiquidIlAdapter` (SLUG `"liquid-il"`): `parse_raw`
   returning our template wrapper (render/render!/render_to_output_buffer);
   env-var validation gains the third value; `forced_liquid_adapter` gains
   the third elsif. THE HARDEST PART is the context shim — mirror
   `ContextShim` exactly:
   - `method_missing` → wrapped `Liquid::Context` (assigns, registers,
     `handle_error` stays Ruby-side — LiquidIL's error text formats already
     match reference per liquid-spec, but SFR error rendering flows through
     `Liquid::Context#handle_error`, so route errors there rather than
     emitting our own inline text);
   - scope reads/writes, scope stack, resource accounting → LiquidIL `Scope`
     stashed at `registers.static[:liquid_il_scope]`;
   - `new_isolated_subcontext` → isolated scope (our `isolated_with`);
   - interrupt handler → graceful-timeout sets our scope interrupt;
   - strainer rebinding so storefront's Ruby filters (registered globally on
     `Liquid::Environment.default`) execute against the shim. Bridge their
     registry into `LiquidIL::Filters.register` at boot (host-filter dynamic
     dispatch path; our compile-time-known builtins already overlap and are
     reference-conformant per liquid-spec).
5. **Tags port — the real volume**: `layout`, `render`, `section`,
   `content_for`, `block`, `schema` (+ the JSON section-compiler axis gated
   by `json_compilation_enabled?`). Map onto `LiquidIL::Tags.register` IL
   emission (the shopify_mock stylesheet tag shows the pattern). Enumerate
   `app/liquid/tags/*` first and triage: many may be thin.

### Phase 2 — caches

6. `CompiledTemplateCache` generalization (or a sibling
   `LiquidIlArtifactCache` if generalizing liquid-vm's is too invasive):
   same key discipline + Ruby-version/platform in vary_key + the fingerprint
   preloader wired to partial artifacts.
7. **In-process live-proc LRU — the differentiator.** liquid-vm's "local"
   tier is a same-host memcached daemon: every request pays a socket hop +
   deserialize. LiquidIL's `TemplateCache` (byte-budgeted LRU holding live
   procs; `LruMemoryCache` at 200MB is the in-repo precedent, ES-only today)
   keyed by the same cache keys makes hot templates render at the in-process
   number (68µs vs 92 on the scoreboard). Multi-tenant breadth is the
   argument FOR it, not against: content addressing means one hot
   theme-store snippet is ONE entry serving thousands of shops.

### Phase 3 — verify, then roll

8. Land dark (forced-chain only). Internal self-verify smoke via header.
9. sfr-verifier: configure a replay share with
   `X-SFR-Self-Verify-Features: liquid-il` (external repo/service change).
   Burn down body diffs — each diff is a conformance finding; feed the same
   triage pipeline as the fuzzer (spec it upstream or fix the engine).
   Watch cohort-tagged stats for latency + `CompiledTemplateCache` hit rates.
10. Per-shop `f_liquid_il_rendering` percentage rollout at the
    `from_context` fallthrough; canary cache-write suppression carries over
    unchanged.

## Gates

- LiquidIL repo: every phase-0 change under the standing gates (`rake test`
  green, `bench:cold` validation, scoreboard quoted, compile-time A/B for
  backend passes).
- Storefront repo: their test suite + verifier-diff burn-down to zero before
  any cohort.
- The scoreboard claim to beat, from their own wiring: liquid-vm pays
  node-local memcached + deserialize per template per request; LiquidIL's
  target is artifact-load ≈ 2µs/KB on miss and ~zero on live-proc hit.
