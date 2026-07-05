# Batch 4 triage summary

Classes owned: fuzz_json, fuzz_split, fuzz_compact, fuzz_default, fuzz_join,
fuzz_uniq, fuzz_sort_natural, fuzz_sort, fuzz_first, fuzz_escape,
fuzz_escape_once, fuzz_upcase, fuzz_strip_newlines, fuzz_strip, fuzz_capitalize,
fuzz_url_encode, fuzz_url_decode, fuzz_lstrip, fuzz_rstrip, fuzz_reverse,
fuzz_last, fuzz_downcase, fuzz_slice, fuzz_remove, fuzz_append.

**106 findings -> 6 behavior rules + 5 dropped -> 13 specs, 2 reference-bug
entries (1 message-leak + 1 sibling-inconsistency observation).**

Most of these 106 are the same handful of root causes wearing 25 different
terminal-filter costumes: the fuzzer classed each finding by its *last* filter,
but the divergence almost always lives upstream (a `truncate: nil` arg, a
`json` filter that reference lacks, a property access on an integer). The rules
below are extracted from the real root cause, not the class name.

## Rules and verdicts

### G1 -- truncate/truncatewords short-circuit nil input before coercing args
`nil | truncate: <anything>` and `nil | truncatewords: <anything>` return nil
(empty) in reference, because both have `return if input.nil?` *before*
`Utils.to_integer(arg)`. LiquidIL coerces the arg first and raises
`invalid integer`. The trailing filter (upcase/join/escape/...) is incidental:
it just operates on the empty/nil result.
**Verdict: SPEC.** `truncate_nil_input_skips_length_argument`,
`truncatewords_nil_input_skips_word_count_argument` (complexity 540/545).
LiquidIL should reorder its nil-guard before arg coercion.

### G2 -- unknown filters pass input through unchanged
Reference has no `json` filter; unknown filters are no-ops (verified even in
strict mode, no parse error). `nil | json` = nil -> "", `42 | json` = 42.
LiquidIL ships a non-standard `json` filter (renders "null"/"Null"/"NULL"),
hence the divergence. The reference *rule* worth donating is generic
unknown-filter passthrough, using a clearly-nonexistent filter name (speccing
`json` itself would wrongly forbid the extension).
**Verdict: SPEC.** `unknown_filter_returns_input_unchanged`,
`unknown_filter_in_chain_passes_through`, `unknown_filter_on_number_returns_input`
(complexity 200/205/205). LiquidIL: drop `json` or exclude LiquidIL-only filters
from the fuzzer.

### G3 -- required-argument filters raise when called with no argument
`split`, `remove`, `append`, `prepend`, `replace`, `modulo` need an argument;
with none, reference renders `Liquid error: wrong number of arguments (given 1,
expected 2)`. LiquidIL silently no-ops (returns "" / "[]"). The behavior
(error, not default) is a contract; the exact message leaks Ruby arity ->
reference_bugs.md #1.
**Verdict: SPEC (behavior) + reference-bug (message).**
`filter_missing_required_argument_raises` (split),
`filter_missing_required_argument_raises_remove` (complexity 500/505,
render_errors). LiquidIL should error instead of no-op.

### G4 -- array filters wrap a scalar/nil as an array; arrays render bracket-free
`5 | uniq` -> "5", `0 | compact` -> "0", `nil | sort` -> [] -> "". Reference
wraps the scalar in a one-element array and renders array output by
concatenating elements with no separator. LiquidIL renders `[5]`/`[0]`/`[]`.
**Verdict: SPEC.** `array_filter_uniq_wraps_scalar`,
`array_filter_reverse_wraps_scalar` (complexity 330/335). LiquidIL: stop
inspecting arrays on output.

### G5 -- member access on a scalar (number) resolves to nil, not an error
`(nil..nil)` iterates once with the value 0; `0.title` / `0["title"]` / bare
`[expr]` lookups resolve to nil in reference. LiquidIL raises
`no implicit conversion of String into Integer`.
**Verdict: SPEC.** `property_access_on_number_returns_nil`,
`bracket_access_on_number_returns_nil` (complexity 200/205). LiquidIL: return
nil for member access on unsupported types; parse leading `[expr]` as a lookup,
not an array literal.

### G6 -- case renders every matching when clause (no break)
`{% when 1 %}a{% when 1 %}b` with subject 1 -> "ab"; `{% when 1,2 %}A{% when 2 %}B`
with 2 -> "AB". Each matching clause runs in order; comma values match if any
equals the subject. LiquidIL runs only the first match.
**Verdict: SPEC.** `case_when_duplicate_value_renders_body_twice`,
`case_when_multiple_matching_clauses_all_render` (complexity 500/505). Existing
case specs only use mutually-exclusive values, so this quirk was uncovered.

## Dropped (5)

- `cf9671254bbe` (sort_natural) -- hash renders as `{"id"=>{}}` (Liquid's own
  inspect, `=>` no spaces). LiquidIL leaks Ruby 3.4's `{"id" => {}}`. Already
  covered by `liquid_ruby/array_to_s.yml`. LiquidIL should use Liquid's inspect,
  not Ruby's Hash#inspect.
- `bbad8f80d2f3` (sort), `062257c44131` (capitalize) -- `{{ forloop | f }}`
  renders the drop's class name (`Liquid::ForloopDrop`). Drop#to_s class-name
  leak already documented/covered in `liquid_ruby/standard_filters.yml` and
  `security_drops.yml`. LiquidIL diverges only by dropping the `Liquid::` prefix.
- `a76f64edebf8` (strip) -- root cause is an empty `{% if cond %}{% endif %}`
  body eliding condition evaluation (so a Float>=String comparison never
  raises); `nil | strip` == "" matches reference. Out of filter scope; LiquidIL
  should not evaluate dead conditions.
- `1e1c9e77f098` (last) -- `count | strip | last` on undefined `count` is basic
  nil-safety (`strip(nil)`=="" , `last("")`==""); covered by
  `basics/filter-nil-safety.yml`. LiquidIL errors on the nil chain and should
  match the nil-safe behavior.

## Finding-hash -> rule map (all 106)

- **G1** (truncate/truncatewords nil-input): 0480cebc2108, 26addf605ee5,
  c6c9c39af189, f706cbf22560, 0693c71a21c7, 0bbfe68e1032, a8092861c465,
  d24b7be58c93, 3f720a2e5943, 6c0f5313daee, b6b07c16a9c9, bdec0bc4603c,
  ae7a716a7266, 00f1f636c21e, 4b8d7da8892d, 182e3cf6b3d1, 49415cbfbc60,
  742db4525e35, 5f20fb0f33b0, 9c9574b74911, c2fbb32e1acf, a45d388ffa55,
  8b1cf9865d05, 31d1b01fb0b1, 34e54ad8d242, 897f19875901, aa59bb0ee867,
  c1e5985592fc, 7796b600e0be, b84d003f725d, 76a1681f2b5a, 7d77d2e3e816,
  87c3f17af887, 32be235e86df, 7dfaa012a1b4, b78e19866dd8, 967bc5d8e5e6,
  7b8fefd47179, 89991ba3cd5b, 17a16d6559f1, 3f6e82ba0080, dfdceb013eca,
  56d409414c43  (43)
- **G2** (unknown/json passthrough): 3166b38d76e1, 35db9f49f693, 455c5752f873,
  5acd71aad879, 89bd3e2f8a8b, ac3ad491f2e5, bfe86671765f, c234d1eb3922,
  ce790ca1945c, deec0e3bf958, fd3c756b2c2c, d75200fbf933, b61663d74197,
  30f41e71f27d, 71236a0c30d4, 9b3c206aee37, 87c8c7098003, 366d707f16fd,
  4225cdb2ad39, 79703fd21f7e, 9114c8491fad, e6d018c615cf, 7993a044483c,
  a10d25bd2140, fda8566733ce, 87bebc42ea39, a5fdb2e392a6, c08ac5762c96  (28)
- **G3** (missing required arg): 15610f8411d9, 72f30ba7fdd6, 75d9b39e869e,
  abf3719442ca, afcfd594708f, b99629ada9ef, ceab79419334, e2a34ac258d1,
  e7795649ef09, 977267185d2b, 3c1a9d17b7e0, 2c93a9bc5d55, d3d2506c9a01  (13)
- **G4** (array filter on scalar/nil): e855db4c39fe, f344571b3156, 04734f69fde7,
  7c934a5b0fb0, a778b8b81ab9, 9bd2d8abb8bc, a31d705d0922, c717bb090c0a,
  3e7afd0ee8fb, a5223b0ae001  (10)
- **G5** (member access on scalar / bracket-lookup): dda61b17b8f0, bd06d3c8b75c,
  d36bf2c3b15e, 4b8bb834b0a5, badcfcf0e762, 5b81dde6ded5  (6)
- **G6** (case renders all matching whens): e81dbe1bd250  (1)
- **DROP**: cf9671254bbe, bbad8f80d2f3, 062257c44131, a76f64edebf8, 1e1c9e77f098  (5)

Counts: G1=43, G2=28, G3=13, G4=10, G5=6, G6=1, DROP=5. Total 106.
