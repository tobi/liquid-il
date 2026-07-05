# Batch3 triage summary

Classes: `truncate` (20), `truncatewords` (16), `floor` (9), `round` (8),
`ceil` (8), `abs` (7), `times` (1), `divided_by` (1), `at_least` (1),
`size` (11), `id` (15). **97 findings in.**

All expected values were reproduced against the reference `liquid` gem in
strict mode. The 97 findings collapse to a handful of behavior rules; most
findings are the same rule seen through different tag wrappers.

## Rules and verdicts

| Rule | Description | Verdict | Spec name(s) |
|------|-------------|---------|--------------|
| R1 | `truncate`/`truncatewords` short-circuit to `""` on **nil input**, *before* coercing the length arg — a nil/non-numeric length does not raise "invalid integer" | **SPEC** | `truncate_nil_input_skips_length_coercion`, `truncatewords_nil_input_skips_length_coercion` |
| R2 | Numeric filters `abs`/`ceil`/`floor`/`round` coerce non-numeric input (nil, non-numeric string) to **0** | **SPEC** | `abs_non_numeric_string_is_zero`, `ceil_non_numeric_string_is_zero` |
| R3 | `size` of nil/non-collection = 0; int->8 / float->0 quirk | **DROP** — covered by `basics/filter-nil-safety.yml` (`missing \| size` = 0) and `liquid_ruby_lax/variable_type_filters.yml` (int-size quirk) |
| R4 | `nil \| json \| size` = 0 | **DROP** — bundled gem has no `json` filter (pass-through: nil stays nil, size 0). Fuzzer noise from filter-set mismatch; LiquidIL ships `json` (`null`, size 4) |
| R5 | A filter error inside `{% assign %}` is **swallowed**; the target var is left undefined; rendering continues (contrast `{{ }}`/`echo`, which print the error) | **SPEC** | `assign_swallows_filter_error` |
| R6 | Ordering operators `< > <= >=` work between two **strings** (lexicographic; equal strings satisfy `<=`/`>=`) | **SPEC** | `string_lexical_ordering`, `string_less_than_or_equal_ordering` |
| R7 | Mixed number-vs-string ordering raises `comparison of X with String failed` | **DROP** — covered by `shopify_production_recordings/recorded_specs.yml` |
| R8 | A **blank** `if`/`unless` block (all branches empty) never surfaces a condition-evaluation error | **DROP** — obscure blank-node optimization detail; error type already covered (R7); only 1 finding hinges purely on it |
| R9 | Dot/bracket lookup on a **scalar** (int/float/string/bool) resolves to nil, never raises | **SPEC** | `scalar_property_lookup_returns_nil` |
| R10 | `{%-`/`-%}` whitespace trim does **not** reach into a preceding `{% raw %}` block's output | **SPEC** | `raw_output_not_trimmed_by_following_tag` |
| R11 | `case` runs the body of **every** matching `when` (no break); a `when a, b` list matches per value | **SPEC** | `case_runs_every_matching_when`, `case_when_list_repeats_body_per_match` |
| R12 | `["str"]` bracket-literal expression evaluates to nil (Liquid has no array literals); parser tolerates emoji/odd chars inside | **DROP** — obscure parser edge; LiquidIL divergence is a parser bug, not a contract |
| R13 | `cycle "a, b"` (comma inside a quoted string) renders `""` | **REFERENCE-BUG** — reference_bugs.md #1 |
| R14 | `render`-without-filesystem error captured inside `{% capture %}` (never displayed) | **DROP** — filesystem-config noise; output hidden |
| R15 | `tablerow` over nil renders nothing | **DROP** — covered by `recorded_specs.yml` (`tablerow_renders_empty_string_when_lookup_returns_nil`) |
| R18 | `decrement total` writes a counter that shadows `total`, changing a `case total` subject re-evaluated per `when` | **DROP** — obscure composite quirk; 1 finding |
| R19 | String filters (`upcase` etc.) coerce numeric input via `to_s` (`0.0 \| upcase` = "0.0") | **DROP** — minor; only reachable via a capture-hidden finding; LiquidIL upcase raising on BigDecimal is a bug to fix, not a spec gap |
| — | Filter arity error leaks Ruby `wrong number of arguments (given 1, expected 2)` | **REFERENCE-BUG (minor)** — reference_bugs.md #2 |

## LiquidIL should fix its side regardless (independent of spec verdicts)

- **Null byte U+0000**: applying a string filter (`lstrip`/`upcase`/`downcase`/
  `strip`/`rstrip`/`capitalize`) to an **undefined variable**, then a numeric
  filter, yields a null byte in LiquidIL; reference yields `""` then `0`. Drives
  the bulk of `abs`/`ceil`/`floor`/`round`/`size` findings. (R2/R3)
- **`truncate:`/`truncatewords:` coerce the length before the nil-input check** —
  reorder so nil input returns `""` first. (R1)
- **String<->string ordering comparison unsupported** — LiquidIL raises
  `comparison of String with String failed`; strings are comparable. (R6)
- **Scalar property lookup leaks Ruby `TypeError`**
  (`no implicit conversion of String into Integer` from `0["title"]`) instead of
  nil. (R9)
- **`{%-` strips a preceding raw block's trailing newline.** (R10)
- **`case` executes only the first matching `when`** instead of all matches. (R11)
- **`tablerow` over nil emits an empty `<tr>`** instead of nothing. (R15)
- **Parser chokes on `["...emoji..."]` / quoted specials** in conditions. (R12)

## Finding-hash -> rule map (compact)

**truncate (all R1):** 0b94d62b357b, 0e4d618afc64, 1e9de1ca3eb6, 1fcabf679d44,
2863b5559668, 40917e95611a, 458fd2794ea4 (+R9), 4b4ecb1aedef, 5cbd5eaa9ca5,
76d8c4ca8f60, 79e2d347f412, 807d54b5e2c8, b10a68a8bc9a, b155158c279a,
c1b4148b8ebe, d40493133a1e, de50829c143c, e301921bb8dc, e705b53f762e,
e81b4a71c1e6.

**truncatewords (all R1):** 00280d562f3a, 05a88e6276a9, 30fb2e4df300,
42bb094366a1, 430d8a28f8fa, 4e01b7fe0f42, 4f434186fdd5, 57f4558afa93,
6748be03ec77, 73936022320d, 97cd61471d00, 9b1793600bb4, ab532a1802cb,
d355b9673bbf, f614d955c787, ff5d8f57c2bb.

**abs:** 70c74d757b7c (R1+R2), 86aa44ceb246 (R2+R9), a1ce738f4972 (R2),
d7f5fa0229c7 (R2), dddcc32cbc06 (R19+R2, hidden), fa9179596839 (R1+R2),
ffceea09151c (R2).

**ceil:** 03208c8bbae7 (R2), 3701b0622427 (R2), 94dcdb5f4527 (R2),
9c15f87392a5 (R1+R2), b7aab891f6e8 (R2), bddabce4c050 (R2), e91df6af3cf5 (R2),
eb59f2b8b79d (R2).

**floor:** 24f048b06aac (R11), 3afb74ce23e7 (R2), 65bc82499945 (R1+R2),
6fbd4d7d25bb (R2), c867bb036c53 (R1+R2), cab9dc3b2b3f (R1+R2), d7585f64d511 (R2),
da9ce3db5f7d (R2), ebfe622be765 (R2).

**round:** 1855a26bd7f6 (R2), 693a5d6f470d (R11), 805a4381eaab (R2),
a02956e1b922 (R1+R2), accd381a92bf (R2), ccb5d36a28fc (R11),
f29cf61ff444 (split-arity leak, refbug#2), f69f01b0cdb9 (R1+R2).

**times/divided_by/at_least (all R5):** 29f9eab41cc1, f3646009f45c, 595133b4948f.

**size:** 12e83fd0f280 (R3), 1ca0a9e8a134 (R3), 2af09de708c2 (R3),
34a8bff8bde7 (R1+R3), 474706408958 (R4), 499d5f8bc23e (R1+R3),
964c3e02ad85 (R1+R3), 9bdff3969a3a (R3), aa0477e07156 (R1+R3),
b296bfdd8211 (R3), d14ccf4d888d (R4).

**id:** 2f00e98083aa (R6), 4855848732ce (R6), 4875786bffe3 (R9),
5477230a0c96 (R15), 5cfb2101c594 (R6), 60be8ded93ec (R10),
66e979858690 (R13 / refbug#1), 6953f15045f4 (R9), 6b149e1229d5 (R9),
755dc6dd6dea (R12), 8ac735a54f63 (R7/R8), 8b3c34c74afe (R12),
aab5d715f86b (R18), ac34f5811b44 (R9), c3ab69ca7113 (R14).
