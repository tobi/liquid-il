# Batch1 triage summary

Classes: `for` (64), `unless` (14), `tablerow` (4), `raw_tag` (5), `raw` (1),
`cycle` (10), `misc` (2) = **100 findings**. All reproduced against reference
`liquid` 5.12.0, `error_mode: :strict`. The findings collapse into a small set of
behavior rules; most are LiquidIL bugs against already-covered/sane reference
behavior.

## Rules and verdicts

### SPEC rules (8 specs, in curated.yml)

- **R-BLANK** — A fully-blank if/unless body (all branches only whitespace /
  comments / nested blank tags) makes the tag a "blank" tag: reference does not
  render it and does not evaluate its condition, so a condition that would raise
  at render time (e.g. a type-mismatch comparison) yields no output and no error.
  Adding any visible content (even `{{ '' }}`) makes the condition evaluate.
  -> SPEC `blank_conditional_body_skips_condition_evaluation`.
  Existing coverage note: `liquid_ruby_lax/specs.yml` documents this only for
  *unknown operators in lax mode*; the strict-mode runtime-error flavor was
  uncovered. This is LiquidIL's single biggest miss (it evaluates the condition
  and raises). LiquidIL should implement the blank-tag pruning.

- **R-CASE** — `case` does not short-circuit: every `when` condition equal to the
  subject renders its body, in order; a comma list is a set of independent match
  conditions, so a repeated value renders the body once per repetition. else runs
  only if nothing matched. -> SPECs
  `case_when_matches_render_body_once_per_matching_value`,
  `case_multiple_when_clauses_all_matches_render`. (Existing `case_multiple_values`
  only shows ANY-of matching, not per-match repetition.)

- **R-RANGENIL** — Range endpoints coerce to integers; nil->0. `(nil..2)`==`0..2`,
  `(nil..nil)`==`0..0` (one element), `(2..nil)`==`2..0` (empty). -> SPEC
  `range_literal_nil_endpoint_coerces_to_zero`.

- **R-FORSTR** — `for` over a String is a single-element iteration binding the
  whole string (never char-split); over a non-enumerable scalar (number/boolean)
  it iterates zero times. -> SPEC `for_over_string_yields_whole_string_once`.

- **R-TRIM** — Whitespace trim markers (`{%-`,`-%}`,`{{-`,`-}}`) strip only the
  literal text node adjacent to them in source; an intervening tag blocks the
  trim, and a preceding `raw`/`comment` block's emitted content is not trimmable.
  -> SPECs `whitespace_trim_does_not_reach_across_preceding_tag`,
  `whitespace_trim_preserves_raw_block_content`.

- **R-CYCLE-LIT** — `cycle` outputs the string form of its current value
  (booleans as `true`/`false`, not empty) and advances per invocation within a
  group. -> SPEC `cycle_renders_literal_booleans_and_advances`.

### REFERENCE-BUG rules (4, in reference_bugs.md)

- **REF-CYCLE-COMMA** — `cycle` splits markup on commas inside a quoted string,
  mangling `"a,b,c"` into undefined variable refs -> empty.
- **REF-DROPSTR** — internal drops stringify to their Ruby class path
  (`Liquid::ForloopDrop`, `Liquid::SelfDrop`) — implementation-detail leak.
- **REF-TOKENIZER** — the tokenizer ends a tag at the first `%}` even inside a
  quoted string, emitting nonsense text; LiquidIL's SyntaxError is defensible.
- **REF-ARITY** — `{{ nil | divided_by }}` leaks a raw Ruby arity `ArgumentError`
  message; also a `(line N)` error-prefix format mismatch.

### DROP rules (already covered or noise)

- **R-MEMBER** — member/index access on a scalar (int/float/bool/string,
  non-command key) returns nil. Already covered by
  `basics/error-handling.yml` (`property_access_on_non_object_lax/strict`,
  `array_access_on_non_array_lax`). LiquidIL bug: it does a raw Ruby `[]`
  (-> "no implicit conversion of String into Integer" / "undefined method '[]'").
  LiquidIL should return nil.
- **R-BRACKET** — bare `[expr]` value (e.g. `{% cycle [0] %}`, `tablerow r in
  [nil]`). liquid-spec has already *decided* this is a parse error
  ("Bare bracket access is not allowed. Use self['...'] instead",
  `parser_errors/cycle.yml`) rather than a lookup. LiquidIL treats `[x]` as an
  array literal (renders the element) — wrong in both worlds; should be a parse
  error.
- **R-CYCLE-EMPTY** — cycling a value that renders empty (nil / `[]` / `{}`) -> "".
  General nil/`to_s` rendering; not cycle-specific. LiquidIL renders `[]`/`{}`.
- **R-TABLE-NIL** — tablerow over a nil/undefined collection -> "". Covered by
  `liquid_ruby/manual.yml` "Tablerow renders empty string when lookup returns
  nil".
- **R-HASHFIRST** — `hash.first` == `[key, value]` (2-element array). Documented
  quirk (QUIRKS.md Hash First/Last); tablerow-over-array is basic. Not re-specced.
- **R-FORDROP** — `for`/`tablerow` over a non-enumerable (a drop, nil) yields no
  iterations; folds into R-FORSTR / R-TABLE-NIL. LiquidIL wrongly iterates once.
- **NOISE** — `for_6e1a804d6424` (`{% when .first %}` + bare `{% increment %}`):
  mixed increment/parse edge outside these classes' rules.

## Finding -> rule map

### cycle (10)
- R-CYCLE-LIT: 08020e920409, 3275f173af7e
- R-BRACKET: 0b09309c4048, 471f07750dc1, 61dbaa5ce3e3, dbb28efa25a2
- R-CYCLE-EMPTY: 662d67384089
- R-MEMBER: d23eb8ea4c11, d7b9a4f635c4
- REF-CYCLE-COMMA: cb51acd5e73d

### unless (14)
- R-CASE: 174079ec64bd
- R-CYCLE-LIT: 1f5c6f919070
- R-BLANK: 4b65d41f85e0, fefb34804d54
- R-BRACKET: 665a17b4d4c0, 8d61c346b6d7
- R-CYCLE-EMPTY: ba4d6c3dbd86
- R-MEMBER: 19b944f46738, c084a4a03910, c2d8792b29e6
- REF-TOKENIZER: 2222ff3fa000, d34f55f106e1
- REF-DROPSTR: a365b216e4b1
- REF-CYCLE-COMMA: fa97fb82bfa5

### tablerow (4)
- R-RANGENIL: 218f5ddd1884
- R-BRACKET: 9f3e95552412
- R-TABLE-NIL: c3e1ce628c39
- R-HASHFIRST: d1bf686d83d8

### raw_tag (5) + raw (1)
- R-TRIM: 2e5c087e68af, 5905d1c77dd7, 919b8783bb82, 9b7d756705b5, cf7682433b5f, 6df9451ad69d

### misc (2)
- REF-TOKENIZER: 0c7454a2bc39
- REF-ARITY: ac945a73e868

### for (64)
- R-CASE: 0f4ec637ab7f, b203b59091be
- R-CYCLE-LIT: 07b4fd8778bb, 531c1a9dfcb5, 7e6648c8306b, ea2298afa334
- R-FORSTR: fd00fcbd39a6
- R-RANGENIL: f0305bb2fa74
- R-BLANK: 25b257a4aee5, 6963744b21b7, 7d7af672b9b7
- R-MEMBER: 02195f9cad0b, 077578a9c4b1, 29cf71ade2e1, 310e2c6761b1, 35b3e717fb71, 3749721c8764, 3dca3ede34d9, 5225b5ca9e71, 5702c8dd3fdd, 5a140ce278f6, 72ff59568daa, 75d3ff8834d0, 7249ab0aa56f, 7d80baff69cc, 89607e8c74a9, 9c3f6e0cf8fd, a21e319b2524, ab49aac0b845, b45b4bb6deaf, b9d6e3a0d1ec, c2ebe382de9a, d39912c8aad1, d5823c7b92f5, d73bd32fd950
- R-BRACKET: 0ac843050214, 3218f6e68c99, 3c9c871dbf06, 536e6c3c5442, 748187a025b0, 8b38bcf32e62, 942fac0cc2b5, 9194e7fe4406, a4e523f0d069, b04df0774f85, b1ab2c512221, ca07b60659ba, f7e12d35076e
- R-CYCLE-EMPTY: 3f7dbda1a7a5
- R-FORDROP: 12036b87a5dc, 7a5411eee4a4, 7ef3826d2a1b, efb0c08768bf
- REF-DROPSTR: 164f3cdd5e24, 386f38c7d0a2, 53dab3be7b46, 5166c65e9871, 68373d6fee17, b663bd3915aa, bef8636ecc18, cb4674f9c5c9, dae6f584e107, e852473159e2
- NOISE: 6e1a804d6424

## Counts

- Findings in: **100**
- Distinct rules: **17** (6 SPEC, 4 REFERENCE-BUG, 7 DROP)
- Specs written: **8**
- Reference-bugs: **4**
- Findings mapped to DROP/covered/noise: majority (R-MEMBER 27, R-BRACKET 20,
  REF-DROPSTR 11, R-CYCLE-EMPTY 3, R-FORDROP 4, R-TABLE-NIL 1, R-HASHFIRST 1,
  NOISE 1).

## LiquidIL-side bugs to fix (regardless of spec verdict)

1. Member/index access on scalars must return nil, not raise (R-MEMBER, ~27
   findings) — biggest correctness gap.
2. Implement blank-tag pruning so blank if/unless bodies don't evaluate their
   conditions (R-BLANK).
3. Bare `[expr]` values should be a parse error (R-BRACKET), not array literals.
4. Whitespace trim must not reach across a preceding tag / into raw content
   (R-TRIM).
5. `cycle` should render boolean literals and empty/nil values correctly; range
   `nil` endpoints coerce to 0; `case` must not short-circuit; `for` over a
   String iterates once with the whole string.
