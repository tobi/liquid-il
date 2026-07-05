# Triage summary — fuzz_if_* (63) and fuzz_case_* (36)

Reference: Shopify/liquid 5.12.0, `error_mode: :strict`, `line_numbers: true`.
99 findings collapse into 8 underlying rules. Only the rules whose *if/case
semantics* are the real divergence are spec'd; the many findings whose divergence
is actually in a wrapped construct (cycle, tablerow, increment, lookup, drop
`to_s`, `size`, whitespace) are dropped as out-of-class noise — the fuzzer filed
them under if/case because that is the outermost tag, not because if/case is
where LiquidIL diverges.

## Rules and verdicts

| Rule | Description | Verdict |
|------|-------------|---------|
| R1 | `case` renders the body once **per matching when-value, across all when-clauses, with no break**. `{% when "a","a" %}`->body twice; two `{% when "a" %}` clauses both run. `else` runs only if nothing matched. | **SPEC** x2: `case_repeats_body_for_each_matching_when_value`, `case_evaluates_all_when_clauses_without_break` |
| R2 | Relational `<,>,<=,>=` between a **number and a string** raises `comparison of <Class> with <Class/value> failed` (both respond to the operator, Ruby `<=>` returns nil). | **SPEC**: `comparison_of_number_and_string_is_an_error` |
| R3 | Relational op where one side is **not order-comparable** (bool, nil, array, hash) silently yields **false, no error** — only pairs where BOTH respond to the operator (and neither is a Hash) are compared. | **SPEC**: `comparison_with_non_ordered_type_is_false` |
| R4 | Two **strings** compare **lexicographically**; must not be rejected as a type error. (LiquidIL wrongly raises "String with String".) | **SPEC**: `strings_compare_lexicographically` |
| R5 | A **blank-bodied** control-flow tag **swallows render errors** raised while evaluating it (recorded, not output); a non-blank body renders the `Liquid error (...)` text. Deliberate backwards-compat quirk. | **SPEC**: `blank_control_flow_tag_swallows_render_errors` |
| R6 | Liquid has **no array-literal syntax**; `["x"]` / `[[...]]` in a condition is a bracket **variable lookup** -> nil (strict/lax) or a "Bare bracket access" parse error (strict2). LiquidIL emits a bogus `Unknown operator ...` message instead. | **DROP** — LiquidIL-side parser bug; strict2 behavior already covered by `liquid_ruby/bare_bracket_self.yml`; upstream is removing the strict-mode form. See reference_bugs.md. |
| R7 | Tokenizer splits `{% ... %}` inside a **quoted argument**, leaking a fragment of the source (`"]]] %}`) as literal output text, no error. | **REFERENCE-BUG** (candidate #1 in reference_bugs.md) |
| R8+ | Divergence is in a **wrapped construct**, not if/case: `cycle` value rendering (array->"", hash->"{}", bool->"true"), tablerow, increment/decrement, hash/index lookup, forloop-drop `to_s`, `float.size`, raw/whitespace trimming. | **DROP** — out of if/case class; belongs to those classes; LiquidIL fixes its own side. |

R1's spec also *corrects* the existing `basics/specs.yml#case_basic` hint ("Only
one when block runs"), which is false for duplicate/multiple matches.

## Counts

- **CASE (36):** R1=16, R2+R5=1, R5=1, R7=3, DROP(out-of-class)=15.
- **IF (63):** R2+R5=13, R3=1, R4=5, R5=1, R6=14, R1(wrapped case)=2, DROP=27.

## Finding-hash -> rule map

### CASE
- **R1** (case no-break / duplicate-when): `051e8868cab8`, `1210b745fbdb`, `281648ea8f2e`, `2c3a6d79ca60`, `3ab21881ed93`, `50c2836c35b0`, `5a55a55d463a`, `60c7f9bfa256`, `6ba504c7c212`, `6c9108d2c39c`, `74d06495e808`, `7a7c8eae75a2`, `7c26e3b60d93`, `7eafce296fe0`, `8fd9e56fac54`, `e705fe4f591c`
- **R2+R5** (number/string comparison in blank body): `2e1ab2d41c18`
- **R5** (blank-body error suppression, non-comparison): `a88cad685914`
- **R7** (tokenizer `%}`-in-string leak): `124cfed626ce`, `b59c8e9f0727`, `fe7e6792d599`
- **DROP** (out-of-class): `1004794540c6`(cycle-array), `203a4098b577`(tablerow), `31d0111f8a7e`(cycle-array), `39eb8ef523be`(cycle-array), `4a46fdc90ace`(raw/ws), `4c946dfb8a07`(cycle-array), `a1a5d9333931`(cycle-bool), `a241c23b81de`(lookup), `be9d15da2056`(cycle-bool), `cbd8b5904df1`(tablerow/first), `e3f19b025911`(cycle-bool), `ed999f3cf702`(tablerow), `f399ec4e267e`(no-match+decrement, covered by case_no_match), `f5c75c757c3d`(int-vs-string hash key lookup), `fb9883ade7d9`(tablerow)

### IF
- **R2+R5** (number vs string relational, blank-suppressed): `04c1e9cd756a`, `0787670ec1db`, `0c3786a7a2bc`, `12114cff5754`, `1f4d9e78bce7`, `5d16d5c85fb9`, `8c7c4268e524`, `8f37897fccef`, `99afcb1bd2b3`, `ad5c84a1cb1a`, `d6597f94d8dd`, `efadb326a6aa`, `fd3a33786a09`
- **R3** (non-ordered type -> false): `29065d4d0bdd`
- **R4** (string vs string lexicographic; LiquidIL bug): `41f6f2069019`, `4823586a55c1`, `494b2f01e699`, `b4dd664923db`, `ff2fa8f35f5d`
- **R5** (blank-body error suppression, non-comparison): `f199c3c253e0`
- **R6** (bracket/no-array-literal; LiquidIL bug): `1c7ed1fbe589`, `2d18c2ff31ca`, `4387895b2113`, `462d6ffd551d`, `5d3730425850`, `6b7c785999bb`, `7c1f9aa970f2`, `a0a158957065`, `a0e4524f111f`, `bf1960e5d46f`, `cb0d2f8ab7b6`, `e3ce6baf6527`, `f0f42e3e9e82`, `952922d52dec`
- **R1** (case no-break wrapped in if): `81c0a877b34c`, `e2a197cf172c`
- **DROP** (out-of-class): `05743d548cd7`(cycle/last), `094eee309431`(forloop-drop to_s), `0a327d1badef`(cycle/lookup), `0b174324dc09`(cycle-array), `22d1589fa72f`(cycle-array), `236212c32af0`(cycle-array), `3c014b9a7cf3`(cycle/lookup), `4886f9dda093`(raw/ws), `4c24367ca398`(cycle-array), `565dd23ffb85`(cycle-array), `5e3700fde659`(cycle/lookup), `635bf0ae0c0e`(cycle-bool), `63ee48e68a68`(cycle-array), `7d605c991d00`(tablerow), `86185f79ef8a`(cycle-bool), `9609181c0982`(cycle-bool), `962bbb88f050`(lookup), `967ae95b4e0d`(tablerow), `b67d82d28167`(cycle-bool), `bafdc4aedbf4`(cycle-bool), `c0a6e004cae9`(cycle-array), `e88b94573776`(cycle-array), `ecead1f12236`(cycle-array; also empty-array-truthy, covered), `edca88f0ac4a`(raw/ws), `f524c5055a5b`(float.size->nil quirk), `f6adbfd2975e`(cycle-bool), `f81d748b11bd`(lookup)

## Note to LiquidIL (side-fixes, regardless of spec verdict)

1. **String-vs-string ordering must not raise** (R4) — LiquidIL raises "comparison
   of String with String failed" where reference compares lexicographically.
2. **Bracket expressions** (R6) — stop emitting `Unknown operator ...`; either
   resolve `[...]` as a nil bracket lookup (strict) or raise the strict2 "Bare
   bracket access" error.
3. **Blank-tag error suppression** (R5) — LiquidIL renders `Liquid error (...)`
   text where a blank control-flow tag should swallow it.
4. Assorted wrapped-construct bugs (R8): cycle value rendering, tablerow row
   counts, increment/decrement gating, `float.size`, forloop-drop `to_s`.
