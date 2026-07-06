# Goal 5: Host-renderer integration — LiquidIL as a pluggable engine

## Objective

Wire LiquidIL into a large multi-tenant host renderer as an additional engine
beside its existing ones, reusing the host's caches that get templates and
partials to the renderer quickly, and prove it **out of band on the host's
shadow-replay verification traffic before any live request touches it**.

NOTE: the detailed reconnaissance of the specific host (internal file
anchors, component names, cache-key formats, header names, rollout
machinery) lives OUTSIDE this repository in the private integration notes.
This document keeps only the engine-side design and the generic
architecture; re-scout or consult the private notes when implementing the
host side.

## Host architecture (generic shape, verified by reconnaissance)

- **Adapter seam**: the host selects a Liquid engine per request through an
  adapter interface. The contract is small: a parse entry point may return
  ANY object responding to `render(context)`, `render!(context)`, and
  `render_to_output_buffer(context, output)`, plus hooks for building parse
  contexts, evaluating bare expressions infallibly, and wrapping the render
  context. Engine forcing per request exists (an internal-only header), and
  the default engine is chosen by env config — no per-tenant flag today; the
  host has an established per-tenant feature-flag idiom to add one.
- **Context bridging precedent**: the host's existing native engine bridges
  its Ruby `Liquid::Context` via a shim: `method_missing` delegates
  everything (assigns, registers, error surface stays Ruby-side); scope
  stack, variable storage, resource accounting, and the interrupt flag route
  to an engine-state object stashed in the context registers; isolated
  subcontexts spawn sub-shims for partials; the filter dispatcher is rebound
  so Ruby filters see the shim.
- **Filters/tags are engine-agnostic**: registered once, globally, as plain
  Ruby modules/classes; engines call them back through the standard
  dispatcher. Only a tiny allowlisted set has native fast-path
  reimplementations, gated per-tenant.
- **Compiled-template cache precedent**: per-FILE compiled artifacts keyed
  `format_epoch+format_digest : content_digest : vary_key(digest of the
  parse options that affect output)`, stored in a two-tier memcached stack
  (node-local daemon → remote cluster), with request-scoped layers:
  a fingerprint preloader (the set of cache keys the previous request with
  the same fingerprint touched — capped at a few hundred — is batch-fetched
  in one round trip) → per-request memo → tiered store → compile.
  Invalidation is purely content-addressed. Shadow-replay traffic suppresses
  cache WRITES on canary; reads are shared.
- **Template supply**: theme assets are content-addressed; per-request the
  host preloads the full name→digest metadata index WITHOUT bodies, and
  fetches bodies lazily per asset (with its own previous-request bulk
  prefetch). Identical bodies are shared across tenants.
- **Verification**: a small sample of production requests is recorded and
  replayed out-of-process against candidate builds; responses are diffed.
  Replays are recognizable per-request, and the replaying service already
  forces per-request feature state via the same header the adapter-forcing
  mechanism reads — so an engine that exists only in the forced-selection
  path is reachable exclusively by replay traffic and internal requests.
- **Runtime**: modern Ruby with YJIT enabled post-fork; per-request error
  mode is strict2 or lax (exactly LiquidIL's implemented matrix); global
  resource limits configured (LiquidIL compiles limit checks in only when
  configured — same shape); output rendered into a caller-provided
  preallocated buffer.

## Architecture decision

Two ideas considered; they are STAGES, not alternatives:

**A. Engine-agnostic compiled-template layer.** Generalize the host's
compiled-artifact cache to be engine-parameterized: `(engine_slug,
format_digest, coder)`. LiquidIL's coder is the framed artifact
(`Artifact.encode/decode`) and its vary_key ADDITIONALLY includes
`RUBY_VERSION` + platform (ISeq binaries are not portable across Ruby
versions; the envelope already stamps this — the cache key must too, or
mixed-version fleets poison each other during upgrades). Keep per-FILE
artifact granularity to inherit, unchanged: cross-tenant sharing,
content-addressed invalidation, the fingerprint preloader, and the
node-local tier.

**B. Verifier-first rollout (ship dark, learn out of band).** An adapter
that exists ONLY in the forced-selection chain (no cohort, no default path)
is reachable exclusively by internal requests and by replay traffic
configured to force it. That yields production-truthful output diffs (the
host's body-diff pipeline = our differential fuzzer at production scale),
real cache-key distributions, hit rates, and latency histograms with ZERO
live exposure. Then, and only then: per-tenant percentage rollout via the
host's feature-flag idiom at the default-selection fallthrough.

## Work plan

### Phase 0 — LiquidIL-side prerequisites (this repo) — ALL DONE 2026-07-05

1. ~~Artifact self-consistency for partial-bearing templates~~ — the engine
   was already correct (loaded artifacts accept a file_system via
   `registers[:file_system]`); the fuzzer's roundtrip oracle wasn't passing
   it. Invariant pinned by test/artifact_self_consistency_test.rb.
2. ~~External partial references~~ — `partial_index` compile mode (name →
   content_digest, no body fetch), EXTERNAL census disposition, the
   `PartialProvider` render-time seam (`_H.epc` routing through the existing
   ipc/rpf/ipf drivers), `Template#partial_dependencies` for composite cache
   keys, optional `SEG_PARTIAL_DEPS` artifact segment. Byte-identical
   emission when no `partial_index` is supplied. Known limitation: include +
   `{% cycle %}` across the external boundary does not share caller cycle
   state.
3. ~~`render_to_output_buffer`~~ and ~~`CompiledArtifact#render_scope(scope)`~~
   (the context-shim seam: a host-owned Scope executes the loaded proc).

### Phase 0.5 — the mock (this repo) — DONE 2026-07-05

`integration/storefront_mock/` is a faithful miniature of the host
architecture above, entirely in this repo: content-addressed mock theme
with fetch counters, two-tier KV mock, minimal Liquid::Context stand-in,
the adapter interface + ScopeShim + router, the engine-parameterized
`CompiledTemplateCache` with fingerprint preloading and the in-process
live-proc `TemplateCache` tier. `test/storefront_mock_integration_test.rb`
proves steps (a)–(i): cold fleet; fingerprint-preloaded fresh process with
zero compiles/zero fetches; live-proc hits (~90µs); content-addressed
invalidation; cross-tenant sharing; a both-engines verifier diff against
reference liquid on every request; external-partial laziness (unreferenced
bodies never fetched, no artifact written); independent partial versioning
(entry key UNCHANGED on external-partial edit); partial fingerprint warming
in one batch read. The adapter + shim files are first drafts of the real
host-side files.

### Phase 1 — the adapter (host repo)

4. The adapter class + slug + env-var branch + forced-selection entry.
   Hardest part is the context shim — mirror the host's existing shim
   pattern exactly (see the mock's ScopeShim and the private notes):
   delegation for assigns/registers, `handle_error` stays on the host
   context (LiquidIL's error text formats match reference per liquid-spec,
   but the host's error rendering flows through its own context), scope
   reads/writes + isolated subcontexts + interrupts route to LiquidIL's
   `Scope`, filter dispatcher rebinding, and the host's global filter
   registry bridged into `LiquidIL::Filters.register`.
5. **Tags port — the real volume**: the host's theme tags (layout/section/
   content-for/schema families and its JSON-compilation axis) mapped onto
   `LiquidIL::Tags.register` IL emission. Enumerate and triage first.

### Phase 2 — caches (host repo)

6. Engine-parameterized compiled-template cache instantiation for LiquidIL
   (Ruby-version-aware vary key; fingerprint preloader wired to partial
   artifacts; composite entry keys folding INLINED partial digests — the
   mock demonstrates why: a process-global live-proc tier would serve stale
   procs after a partial edit if the entry key ignored inlined content).
7. In-process live-proc `TemplateCache` tier — the differentiator: the
   host's node-local tier is still a socket hop + deserialize per request;
   live procs render hot templates at the in-process number. Content
   addressing means one hot shared snippet is ONE entry serving many
   tenants.

### Phase 3 — verify, then roll (host repo + replay service)

8. Land dark (forced-selection only); internal smoke via the forcing header.
9. Configure a replay share to force the new engine; burn body diffs to
   zero (each diff is a conformance finding — same triage discipline as the
   fuzzer: fix the engine or spec the behavior upstream); watch cohort-
   tagged latency and cache hit rates.
10. Per-tenant percentage rollout at the default-selection fallthrough.

## Gates

- This repo: the standing gates (suite green, bench:cold validation,
  scoreboard quoted, compile-time A/B for backend passes).
- Host repo: its test suite + verifier-diff burn-down to zero before any
  live cohort.
- The performance claim to beat: the host's current engine pays node-local
  memcached + deserialize per template per request; LiquidIL's target is
  artifact-load ≈ 2µs/KB on miss and ~zero on live-proc hit.
