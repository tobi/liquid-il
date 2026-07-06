# Goals

Four planned workstreams, each written to be executable without prior context.
Suggested order: 01 → 02 → 03 → 04 (01 finishes the "win all scenarios" plan;
02 guards everything after it).

| goal | outcome | headline metric |
|---|---|---|
| [01-cache-miss-tranche](01-cache-miss-tranche.md) | win the last losing scenario column | cache-miss geomean < liquid-vm's ~412µs |
| [02-differential-fuzzer](02-differential-fuzzer.md) | mechanical semantic-gap discovery vs reference liquid | zero unexplained divergences; findings feed liquid-spec |
| [03-artifact-statement-dedup](03-artifact-statement-dedup.md) | dedupe template-authored repetition into artifact-local lambdas | order_email remote-hit ≤ liquid-vm (76→≤70µs) |
| [04-concurrency-story](04-concurrency-story.md) | verified thread safety + Ractor rendering demo | bench:threads scaling table + Ractor test green |
| [05-storefront-integration](05-storefront-integration.md) | LiquidIL as a pluggable host-renderer engine, proven on shadow-replay traffic before any live request | replay diff burn-down to zero; hot-template renders at in-process speed |

## Rules that apply to every goal

- **Gates before every commit:** `rake test` fully green (5333/0/0 baseline)
  and `rake bench:cold` printing its hard-validation line. Perf claims quote
  all four scoreboard columns (cache-miss / remote-hit / in-process /
  artifact) from a single `rake bench` or `rake liquid_vm:scenarios` run.
- **No regex/scan/gsub over generated Ruby source.** All analysis happens on
  the IL (`@instructions`) or is recorded during codegen (see the
  `Effects` struct and `scope_lookup` in lib/liquid_il/ruby_compiler.rb for
  the canonical pattern). String passes over emitted code have twice caused
  correctness bugs and once cost +80% compile time.
- **Reference behavior wins.** When LiquidIL and the reference `liquid` gem
  disagree, reference is right unless a liquid-spec QUIRKS.md entry says
  otherwise; suspicious upstream specs get flagged (in commit messages and
  to the liquid-spec checkout at ~/src/tries/2026-07-04-Shopify-liquid-spec),
  not silently conformed to.
- **Line numbers drift — use grep anchors.** These docs reference code by
  greppable names, never line numbers.
- Commit directly to main; end commit messages with the Co-Authored-By
  trailer used throughout the repo history.
