# Winning All Scenarios

**Goal:** LiquidIL beats Shopify/liquid-vm (classic and SSA) and reference liquid in **all
three render scenarios, on every benchmark spec** — not just on geomean.

Status: plan. Baselines measured 2026-07-04 on main `0422024` (Ruby 4.0, YJIT), liquid-vm
`b118c553`, via `rake liquid_vm:scenarios`.

## Where we stand

Geomean across the 6 common bench specs:

| adapter | cache-miss | remote-hit | in-process | artifact |
|---|---:|---:|---:|---:|
| liquid_il | 532µs | **97µs** | **63µs** | 9.4KB |
| liquid_ruby | 433µs | — | 185µs | — |
| liquid_vm | **421µs** | 105µs | 88µs | **1.7KB** |
| liquid_vm_ssa | 962µs | 111µs | 94µs | 1.8KB |

- **in-process: won everywhere.** Native Ruby under YJIT beats VM dispatch structurally.
  This is the crown; nothing in this plan may trade it away.
- **remote-hit: won on geomean, lost on the specs with fat artifacts** — cart page
  (107µs vs 94µs, artifact 22.8KB vs 4.7KB), order_email (85 vs 75), leaderboard (89 vs 83).
- **cache-miss: lost** by 26% to liquid-vm and 23% to reference liquid.
- **artifact: lost 5.5x.**

## The diagnosis (measured)

The cart page compiles **6.1KB of Liquid — of which only 2.8KB is unavoidable raw-text
payload — into a 19KB ISeq binary** (22.8KB artifact with envelope). liquid-vm fits the
same template into 4.7KB.

The generated Ruby contains ~210 helper/method call sites and 81 output appends; at
~1,474 disassembly lines for 19KB, we pay **~85 bytes of ISeq per emitted operation**.
liquid-vm pays ~10 bytes per bytecode op. Line tables alone are a verified **7.1%** of the
binary (364 emitted lines; collapsing to one line: 19,080 → 17,724 bytes, identical
instruction count) — and error locations are already compile-time literals, so that
metadata is pure dead weight.

**The key insight: emitted-code size is one lever that moves three columns.**

| emitted bytes are… | …which drives |
|---|---|
| the ISeq binary | **artifact** size |
| what `load_from_binary` parses (~3µs/KB) | **remote-hit** load cost |
| what `RubyVM::InstructionSequence.compile` chews through | a large slice of **cache-miss** |

The arithmetic is forgiving: we do **not** need to match liquid-vm's 1.7KB. Halving the
cart artifact (22.8KB → ~11KB) puts its remote-hit at ~33µs load + 45µs render ≈ **78µs
vs their 94µs** — the render advantage covers the rest. Winning every remote-hit row
requires roughly **artifact ≤ 2× liquid-vm's**, not parity.

## Workstreams

### A. Emitted-bytes warpath (artifact + remote-hit + cache-miss)

1. **`bench:bytes` attribution tool (build first).** Attribute ISeq bytes to codegen
   patterns — output append, lookup, comparison, filter call, interrupt guard, truthy
   wrapper, partial call — per bench spec. Every subsequent change gets measured against
   the pattern it claims to shrink. No vibes.
2. **Compact emission.** Emit dense generated Ruby: no indentation, statements fused onto
   few lines. Verified 7.1% artifact win from line tables alone, plus faster RubyVM
   compile (helps cache-miss). Keep a debug flag that emits today's readable form
   (`bin/liquidil compile` should default to pretty). Mechanical and low-risk; lands first.
3. **Helper-ification sweep (the AGENTS.md "create-runtime nudge", finished).** Any inline
   expansion costing more than ~2–3 ISeq instructions per site becomes a runtime send:
   - truthy wrappers `((_t = X); _t = _t.to_liquid_value; _t)` → `_H.t(X)`
   - `_H.cmp(l, r, :op, _O, "file")` — the `_O` and per-site file-literal operands are
     repeated at every call site; hoist the file literal to one local assigned in the
     prologue, and fold `_O` into a runtime-held reference where possible
   - interleaved append/guard shapes in interrupt-bearing templates
   Each conversion trades artifact bytes for one send in the hot path — the scenario
   table makes that trade visible per change; the **in-process column must not regress**.
4. **Operand dedup.** Repeated string operands (partial names, filter names, file
   literals) become prologue locals or shared frozen constants; audit `putstring` /
   `putobject` duplication in disasm via the attribution tool.

Target: geomean artifact 9.4KB → ~5KB; cart 22.8KB → ≤11KB. Expected to flip every
losing remote-hit row.

### B. Cache-miss residual (need −21% vs liquid-vm)

A.2/A.3 already cut the compile half (less Ruby to generate and compile). The profiled
parse-side remainder (stackprof over the bench suite):

1. **Lexer byte-tables**: `scan_identifier_or_keyword` (4.7% self) and `Regexp#match`
   dispatch (4.9%) are the two largest parse costs; finish the byte-table conversion the
   lexer already started.
2. **Kill codegen string-sniffing (~6%)**: `inline_truthy` and the numeric-compare fast
   path currently **regex the generated Ruby string** to classify expressions. Carry an
   expression-kind tag alongside the Ruby string on the codegen stack instead. (Also the
   last remnant of the "IL is lower-level than its only consumer" smell.)
3. **Skip `link_and_strip` for label-free templates** (4.6%): post-melt, labels exist
   only for loops; most non-loop templates can skip the pass entirely (it has a
   quick path — make it actually free).

### C. Non-goals

- **No artifact compression.** Zstd shrinks the memcache payload, not
  `load_from_binary` time; the measured cost is load, not transfer.
- **No bytecode/VM hybrid.** Compact bytecode would approach liquid-vm's artifact size by
  surrendering the in-process crown that native codegen owns. Rejected.
- **No tuning knobs.** One default configuration, per the project charter.

## Sequencing and gates

| step | deliverable | expected movement |
|---|---|---|
| 1 | `bench:bytes` attribution tool | measurement, no movement |
| 2 | compact emission | artifact −7%, cache-miss −small |
| 3 | helper-ification sweep (guided by tool) | artifact −30–50%, remote-hit flips on cart/email/leaderboard |
| 4 | operand dedup | artifact −5–10% |
| 5 | lexer byte-tables + expr-kind tags + link skip | cache-miss −15–25% |

Every step gates on:

- `rake test` — 5181/5181, no exceptions
- `rake bench:cold` — hard output validation vs fresh compile and reference gem
- `rake bench` — **all four columns reported; no scenario regresses**
- `rake liquid_vm:scenarios` at milestones — the scoreboard this plan is judged by

Done means: every row of `rake liquid_vm:scenarios` shows liquid_il ahead of liquid_vm and
liquid_vm_ssa in cache-miss, remote-hit, and in-process.
