# Goal 1: Win the cache-miss column

## Objective

Cache-miss (parse + compile + render of a never-seen template) is the only
scenario geomean LiquidIL still loses to Shopify/liquid-vm:

| adapter | cache-miss (geomean, n=6 common specs) |
|---|---:|
| liquid_il | 451–475µs |
| liquid_ruby | 425–450µs |
| liquid_vm | 412–428µs |

Target: beat liquid_vm's ~412µs. That means removing ~10% of compile time.
Numbers bounce ±5% between runs — always compare within one run of
`rake liquid_vm:scenarios`, never across runs.

## How to measure (do this first, and after every change)

1. The scoreboard: `rake bench` (three-scenario table vs reference liquid) and
   `PATH="$HOME/.cargo/bin:$PATH" LIBCLANG_PATH=/nix/store/vgnl8fbd1fv0p1vs07vk6a4gi9rzggw0-clang-21.1.7-lib/lib rake liquid_vm:scenarios`
   (adds liquid-vm; needs the env vars for the Rust build).
2. The gates: `rake test` must stay fully green (5333/0/0 at time of writing)
   and `rake bench:cold` must print "All outputs validated against fresh
   compile and reference liquid gem." Run both before every commit.
3. Profiling recipe (this exact harness was used for the numbers below):

```ruby
# ruby -Ilib this_script.rb
require "yaml"; require "stackprof"; require "liquid_il"
doc = YAML.safe_load(File.read(File.join(Gem.loaded_specs.fetch("liquid-spec").full_gem_path, "specs/benchmarks/storefront.yml")), permitted_classes: [Symbol], aliases: true)
specs = doc["specs"]
fss = specs.map { |s| Class.new { def initialize(h) = @h=h; def read_template_file(n) = @h[n] || @h["#{n}.liquid"] }.new(s["filesystem"] || {}) }
specs.each_with_index { |s, i| LiquidIL::Compiler::Ruby.compile(s["template"], context: LiquidIL::Context.new(file_system: fss[i])) } # warm class caches
profile = StackProf.run(mode: :wall, interval: 20) do
  40.times { specs.each_with_index { |s, i| LiquidIL::Compiler::Ruby.compile(s["template"], context: LiquidIL::Context.new(file_system: fss[i])) } }
end
StackProf::Report.new(profile).print_text(false, 24)
# drill into one method's callers: .print_method(/String#gsub/)
```

Caveat: class-level caches (`@@partial_cache`, `@@indent_partial_body_cache`,
`@@iseq_cache` in lib/liquid_il/ruby_compiler.rb) stay warm across profile
iterations, which matches how the bench harness measures "cache-miss" (same
template compiled repeatedly in one process). A truly cold fleet also pays
partial compilation; keep that in mind but optimize against the warm-class-cache
profile since that is what the scoreboard measures.

## Measured hot list (2026-07-05, storefront suite, warm class caches)

| frame | self% | notes |
|---|---:|---|
| Compiler#fused_peephole | 8.2% | the single optimizer pass, walks all IL |
| Compiler#link_and_strip | 4.3% | label→index resolution |
| ExpressionLexer#advance | 3.6% (8.2% total) | expression tokenizer |
| RubyCompiler#compute_hoisted_lookups | 3.5% | separate full-IL walk (see item A) |
| RubyCompiler#build_expression | 3.3% | |
| RubyCompiler#generate_for_loop_body_with_expr | 2.6% + 1.6% String#gsub | re-indent gsub (see item B) |
| String#match?, String#inspect | 2.4% each | |
| TemplateLexer#compute_tag_name | 2.0% | |
| RubyCompiler#peek_statement_kind | 1.8% | |
| fold_const_ops / fold_const_filters | 2.1% / 1.2% | |

`String#gsub` caller attribution (via `print_method(/String#gsub/)`):
84% `generate_for_loop_body_with_expr` (the fast-path re-indent), 10%
`partial_lambda_name` (sanitizing the same partial names over and over),
5% parser. `String#scan` is only 0.2% (adopt_frozen_arrays).

## Work items, in order

### Item A (~3.5%): fold compute_hoisted_lookups into an existing IL walk

`RubyCompiler#compute_hoisted_lookups` (lib/liquid_il/ruby_compiler.rb, find
with `grep -n "def compute_hoisted_lookups"`) does one more full pass over
`@instructions` per template just to count FIND_VAR reads and collect written
names. The optimizer's `fused_peephole` (lib/liquid_il/compiler.rb) already
walks every instruction. Do the counting there:

- During `fused_peephole`'s main scan, additionally maintain `counts` (reads
  per name from FIND_VAR / FIND_VAR_PATH / WRITE_VAR / WRITE_VAR_PATH
  `inst[1]`) and `written` (ASSIGN / ASSIGN_LOCAL / INCREMENT / DECREMENT /
  FOR_INIT / TABLEROW_INIT `inst[1]`; PAGINATE_SETUP marks "paginate" and the
  first/last segment of `inst[1].split(".")`) plus a `hoist_blocked` flag
  (INCLUDE_PARTIAL, CONST_INCLUDE, :SHOPIFY_SECTION_RENDER, or any opcode not
  in RubyCompiler::HOIST_NEUTRAL_OPS).
- CRITICAL: the peephole DELETES and REWRITES instructions (write-cursor
  compaction, constant propagation). Counting during the scan will count
  instructions that later get fused away. That is acceptable in one direction
  only: an OVERCOUNT can at worst hoist a variable that ends up read fewer
  than 3 times (harmless: one extra local, still correct). An UNDERCOUNT of
  `written` is NOT acceptable (hoisting a written variable is a correctness
  bug). So collect `written` from the ORIGINAL instruction stream before any
  fusion applies — safest is: count both sets on the instructions as the scan
  reads them (pre-fusion view), never on the rewritten output.
- Store the result on the compiler output (the optimizer and RubyCompiler are
  different objects — thread it through however `parser.builder.label_counter`
  already reaches RubyCompiler; grep for `label_counter` to see the plumbing).
  `RubyCompiler#generate_ruby` then uses the precomputed data instead of
  calling `compute_hoisted_lookups`. Keep `compute_hoisted_lookups` as the
  fallback when the optimizer is disabled (`optimize: false` still works).
- Also fold the eligible-check for `link_and_strip` here if convenient: it
  already skips when `label_counter == 0`; nothing more is needed there
  unless the profile says otherwise.

### Item B (~3%): stop emitting indentation the production path throws away

This is the answer to "can we do this at an earlier step instead": yes.
`compact_source` (grep `def self.compact_source` in ruby_compiler.rb) strips
ALL indentation and comments from the generated source before
`RubyVM::InstructionSequence.compile` ever sees it. The pretty indentation
exists only for humans reading `template.compiled_source` / `bin/liquidil
compile`. Yet the fast-path loop emission pays a full-body regex gsub per loop
to RE-indent code that will be thrown away:

```ruby
# in generate_for (grep "body_code is at INDENT"):
code << body_code.gsub(/^#{Regexp.escape(prefix)}      /, prefix + "  ")
```

Plan:
1. Add a compile-mode flag to RubyCompiler (e.g. `@pretty` — default false;
   `true` only for the debug/CLI paths that show source to humans). Grep for
   who constructs RubyCompiler and what options flow in.
2. When not pretty: `INDENT[n]` returns `""` for every n (INDENT is a
   precomputed array constant — swap in a frozen all-empty array), the
   re-indent gsubs in generate_for and generate_partial_call become no-ops
   (guard them with `if @pretty`), and comment emissions (lines starting
   `#{prefix}# `) are skipped.
3. `indent_partial_body` with `spaces` becomes a no-op indent when not pretty
   (the inline-splice ARG REWRITES must still run — only the indentation part
   is display-only).
4. compact_source still runs (it also fuses `_O <<` chains and semicolon-joins
   statements — that part is real work, not formatting), but its
   strip/skip-comment work becomes trivial.
5. DANGER — things that key on leading whitespace or line structure:
   - `generate_for`'s body parsing does NOT key on indentation, but
     compact_source's APPEND_LINE regex and `balanced_expr?` operate per
     stripped line — unchanged.
   - `indent_partial_body`'s cache key includes `spaces` — fine.
   - Tests assert emitted shapes (test/ruby_compiler_test.rb,
     test/partial_codegen_test.rb): they match with regexes like
     `/_H\.ei\(/` — mostly indentation-agnostic, but check
     `test_nested_loop_without_parentloop_passes_nil_parent` etc. still pass.
   - `compiled_source` used by bin/liquidil and docs: wire `@pretty = true`
     there so human output stays readable.
6. Expected win: the 1.6% gsub + part of generate_for's 2.6% self + smaller
   String allocations (GC was 3.9%).

Also memoize `partial_lambda_name` (10% of gsub samples): it recomputes
`"__partial_#{name.gsub(/[^a-zA-Z0-9_]/, '_')}__"` for the same names
repeatedly — a per-instance (or class-level, mutex-guarded like
NAME_REGISTRY_MUTEX) hash fixes it in five lines.

### Item C (~4% total): ExpressionLexer#advance and the double-lex

`advance` is 3.6% self / 8.2% total. Two known sub-issues:
- Tag argument markup is lexed twice on some paths (classification peek, then
  parse). Attribute precisely first: stackprof `print_method(/advance/)` and
  look at callers; if `peek_statement_kind` or parser peeks re-lex the same
  span that `parse_*` then lexes again, carry the tokens forward (an array of
  [type, value] built once) instead of re-scanning.
- `scan_identifier_or_keyword` (1.2%) was already optimized with
  StringScanner#skip; remaining cost is per-token dispatch in `advance` — a
  byte-dispatch table (`case b0 = @source.getbyte(pos)` with integer ranges,
  which it may already do — read it first) usually beats regex alternation.
Preserve lexer quirks EXACTLY: the lax-mode behaviors (non-ASCII after ident
ends the expression unless the ident ends in `?`; interior apostrophes in
single-quoted strings continue the string when followed by [A-Za-z0-9]) are
pinned by liquid-spec — `rake test` will catch violations.

### Item D (~8%): fused_peephole self time

Highest single frame but also the most load-bearing code. Only attempt after
A–C. Ideas that don't change semantics:
- The pass dispatches on `inst[0]` symbols via `case/when` over ~30 opcodes
  (Symbol#=== shows at 1.6%). Convert the hot dispatch to a Hash lookup of
  handler indexes or reorder `when` clauses by measured frequency (WRITE_RAW
  and FIND_VAR dominate real templates).
- Skip re-runs harder: re-runs are already conditional on change flags; verify
  with counters that second passes are actually rare on the bench set.
- Do NOT try to skip the pass for "simple" templates by sniffing — every
  template benefits from raw-write merging.

## Constraints

- NEVER analyze or rewrite generated Ruby source with regex/scan/gsub — all
  new analyses go on the IL or are threaded through codegen (see
  `Effects`/`scope_lookup` in ruby_compiler.rb for the pattern, and
  .goals/README.md). String passes over emitted code were measured at +80%
  cache-miss and repeatedly caused correctness bugs.
- Every commit: `rake test` green + `rake bench:cold` validated + scoreboard
  numbers in the commit message (all four columns, from ONE run).
- Watch the in-process column while optimizing compile — it is the crown; a
  compile-time win that regresses render is a net loss.
