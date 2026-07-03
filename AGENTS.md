# AGENTS.md

Instructions for AI coding agents working on this repository.

**Architecture:** See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed pipeline documentation.

## Project Overview

LiquidIL is a high-performance Liquid template implementation that compiles Liquid templates to an Intermediate Language (IL) for optimized execution. The project prioritizes:

1. **Zero-allocation hot paths** - Use StringScanner `skip` instead of `scan`, byte lookup tables, deferred string extraction
2. **Solving problems at the right level** - Parse-time decisions in lexer/parser, compile-time optimizations via IL passes, runtime only when necessary
3. **Code that tenderlove would be proud of** - Performance-conscious Ruby following the patterns in the ruby skill's performance resources

## The Optimization Target (read this before touching codegen)

LiquidIL is optimized for **one** workload, by default, with **no tuning switches**:

> Compile once → persist the compiled artifact (memcache/DB) → in a *different* process that has never seen the template, `blob = memcache.get(key)` → load → render.

The hot path is **deserialize → callable proc → first render**, not warm re-render. Two consequences govern every codegen change:

- **Keep the emitted ISeq small.** The generated Ruby becomes an ISeq binary that we load *cold*, and `RubyVM::InstructionSequence.load_from_binary` cost scales with binary size (~3µs/KB). For realistic templates the cold load costs *more than the render itself*. Smaller emitted code = faster cold start. Before adding an inline expansion, ask: "how many bytes does this add to every artifact that uses it?"
- **Prefer the runtime over the emitted string — the "create-runtime" nudge.** When a code pattern would be emitted repeatedly (per call site, per loop, per partial), **lift it into a runtime helper** (`lib/liquid_il/runtime_helpers.rb`) and emit a single call instead. The runtime library is loaded once and JIT-compiles once, so moving a pattern there costs **zero artifact bytes** and gets compiled to native code a single time — versus duplicating it into every template's ISeq. This is almost always the right trade for anything that isn't a trivial one-liner.

  ```ruby
  # AVOID: ~25 lines of prologue/rescue/ensure emitted per partial call site
  # PREFER: emit one call, put the body in the runtime
  _H.invoke_partial(name, body, assigns, _O, _S, ...)   # helper JITs once, adds ~1 line/artifact
  ```

## JIT / YJIT usage (assume it is always on)

Emitted code runs under **Ruby 4+ with a JIT always enabled** (YJIT now, ZJIT later), with the LiquidIL runtime already loaded and warm. Write generated code for that reality:

- **Minimize branching** in emitted code — prefer a branchless helper call over inline conditionals; the JIT deoptimizes on cold/polymorphic branches.
- **Avoid allocations** in emitted code (reuse buffers, use free-array tricks like `[a,b].max`, don't allocate transient hashes/arrays per iteration).
- **Push hot patterns into the runtime** so the JIT compiles them once and shares them across all templates, rather than re-emitting (and re-JITting) them per template.
- **Never embed the template source or spans in the artifact** — error line numbers and filenames are compile-time literals baked into the emitted code, so the artifact needs neither. (Verified: stripping them leaves error output byte-identical.)

## Security invariant (emitted code runs untrusted input)

Templates are untrusted and are compiled into Ruby *source*. **Never interpolate a template-derived value raw into an emitted double-quoted string** (`"... #{name} ..."`) — that is a code-injection primitive. Emit every template-derived value through `.inspect` / the string-literal helper so `#{...}`, quotes, and backslashes are escaped. Constrain this at compile time: route all string emission through one helper so the dangerous shape is unrepresentable.

## Commands

```bash
# Run the liquid-spec test suite
bundle exec liquid-spec run adapter.rb

# Run tests matching a pattern
bundle exec liquid-spec run adapter.rb -n "for"
bundle exec liquid-spec run adapter.rb -n "/test_.*filter/"

# Quick test a single template
bundle exec liquid-spec eval adapter.rb -l "{{ 'hi' | upcase }}"

# List available specs
bundle exec liquid-spec run adapter.rb --list

# Cold-path benchmark (the optimization target's regression gate):
# artifact decode -> ISeq load -> eval -> first render, medians per spec,
# hard-fails unless artifact/fresh/reference outputs all match
rake bench:cold

# Warm + artifact-load benchmark vs reference liquid (liquid-spec harness;
# the adapter implements LiquidSpec.dump_artifact / load_artifact, so every
# spec reports a "Load" stage: artifact bytes, cold load @1, load+first-render
# cold total, steady-state load time/allocs — with roundtrip verification)
rake bench

# Same comparison on the partial-heavy local suite (specs/partials/ —
# a liquid-spec local suite; expected: blocks generated from reference liquid)
rake bench:partials
```

## Testing convention (write specs for every fix)

Every inline change — parser, lexer, compiler, runtime, filter — must be accompanied by a **local spec** with a descriptive name and a clear comment explaining the root cause and expected behavior. Do not rely solely on the upstream liquid-spec to catch regressions; write a focused spec that would fail without the fix and pass with it.

Guidelines:
- Place focused repro specs in `spec/repros/` as YAML files. `liquid-spec` discovers local specs recursively, so keep repros organized in subdirectories when helpful.
- Use the existing YAML format: `name`, `template`, `expected`, `environment`, `filesystem`, `render_errors`, etc.
- Name specs descriptively: `lax_mode_ignores_trailing_junk_after_expression`, not `test_parse_1`.
- Add a `_metadata.hint` or `doc` field explaining the root cause the spec guards against.
- Test the **behavior**, not the implementation: assert rendered output or raised error.
- If the fix addresses a category (e.g., nil handling in filters, drop truthiness), write specs for multiple representatives of that category, not just the one case that failed.
- Run `bundle exec liquid-spec run adapter.rb` to verify both the new spec and no regressions.
- For Ruby-level unit tests (not YAML specs), place them in `test/` following the existing `*_test.rb` naming convention.

## Architecture

Pipeline: **Source → Lexer → Parser → IL → Linker → VM**

See [ARCHITECTURE.md](ARCHITECTURE.md) for complete details on:
- Two-stage lexing (TemplateLexer + ExpressionLexer)
- IL instruction set and encoding
- VM execution model
- Drop protocol

## Performance Patterns

From the ruby skill's performance guidance:

```ruby
# Use skip instead of scan (avoids allocation)
len = @scanner.skip(/\w+/)
value = @doc.byteslice(@scanner.pos - len, len)  # only when needed

# Byte lookup tables for O(1) dispatch
PUNCT_TABLE = []
PUNCT_TABLE["|".ord] = :PIPE
byte = @source.getbyte(@scanner.pos)
if (punct = PUNCT_TABLE[byte])
  # handle punctuation
end

# Free array optimizations
[x, y].max  # No allocation!
[x, y].min  # No allocation!
```

## Problem-Solving Hierarchy

1. **Lexer/Parser time** - Constant folding, static analysis, syntax validation
2. **IL optimization passes** - Dead code elimination, instruction merging, loop optimizations
3. **Link time** - Label resolution, jump target calculation
4. **Runtime (VM)** - Only dynamic lookups, filter calls, and interrupt handling

## Design Decisions

This project involves many architectural and implementation decisions. When facing choices about:
- IL instruction design
- Optimization strategies
- Performance vs. complexity tradeoffs
- How to handle edge cases
- Where in the pipeline to solve a problem

Use the `AskUserQuestion` tool to get direction. The goal is to build something excellent, not just functional.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
