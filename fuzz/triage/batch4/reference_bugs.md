# Batch 4 reference-bug candidates

Divergences where the reference (`liquid` gem) behavior looks like an accident
of implementation rather than a contract worth enshrining. These are NOT in
curated.yml. Each entry: minimal repro, what reference does, what a reasonable
design would do, why I judge it unintentional, affected finding hashes.

---

## 1. Missing-required-argument error message leaks Ruby method arity

**Repro**

```liquid
{{ "a-b-c" | split }}
{{ "abc" | remove }}
{{ 6 | modulo }}
```

**Reference renders (all three):**

```
Liquid error: wrong number of arguments (given 1, expected 2)
```

**What any reasonable design would do:** report the missing *filter* argument
in filter terms, e.g. `split requires 1 argument` (0 given). The user wrote
zero explicit arguments, so "given 1, expected 2" is actively misleading.

**Why unintentional:** the message is a raw Ruby `ArgumentError` string that
escaped from the filter-dispatch calling convention -- Liquid invokes the
filter method as `split(input, *args)`, so Ruby counts the piped input as the
"1 given" and the arity as "2 expected". Nothing about the template surface has
two arguments or one given; the numbers are an internal detail (the receiver
being passed positionally) bleeding into user-visible output. This is the same
class of leak the taste guide calls out (Ruby internals surfacing in error
text).

**Disposition:** the *behavior* (a required-arg filter with no argument is an
error, not a silent no-op) is a real, stable contract and IS specced
(`filter_missing_required_argument_raises` / `..._remove`). Only the exact
wording is bug-report material. The curated specs pin the current wording (so
they stay green) but Shopify should consider a filter-centric message; if they
change it, those two `expected` strings must be updated.

**Affected findings:** split -- 15610f8411d9, 72f30ba7fdd6, 75d9b39e869e,
abf3719442ca, afcfd594708f, b99629ada9ef, ceab79419334, e2a34ac258d1,
e7795649ef09 (error swallowed by assign); downcase 977267185d2b
(`nil | split | downcase`); remove 3c1a9d17b7e0; append 2c93a9bc5d55; strip
d3d2506c9a01 (`nil | prepend | strip`, gated behind an unentered `if`).

---

## 2. (Observation, low priority) Sibling string filters disagree on nil return

Not tied to a specific output-divergent finding, but a genuine internal
inconsistency worth flagging while adjacent code is under review.

**The inconsistency** (reference `standardfilters.rb`):

- `escape`, `url_encode`, `url_decode`, `truncate`, `truncatewords` return
  **nil** for nil input (`... unless input.nil?` / `return if input.nil?`).
- `capitalize`, `upcase`, `downcase`, `strip`, `lstrip`, `rstrip`,
  `escape_once`, `strip_newlines`, `base64_*` return an **empty string**
  (`Utils.to_s(nil)` == `""`, then operate).

Both render as `""` for a bare `{{ nil | f }}`, so the divergence is nearly
invisible -- but it is observable through filters that distinguish nil from ""
(e.g. `default`, `compact`, truthiness of the intermediate). A single family of
string filters should pick one nil convention. I judge the split accidental
(it tracks whether each author happened to add an early `return if input.nil?`
guard, not any design intent). No batch-4 finding depends on the difference, so
this is an FYI for Shopify, not a spec and not a blocker.

---

## Note: LiquidIL-side fixes (not reference bugs)

Recorded here for completeness; these are LiquidIL divergences to fix on its own
side, independent of any spec:

- **Eager argument coercion before nil-input guard.** LiquidIL raises
  `invalid integer` for `nil | truncate: nil` / `truncatewords: nil` because it
  coerces the length argument before checking for nil input. It should mirror
  the reference order (nil-input guard first). (~30 findings, rule G1.)
- **Non-standard `json` filter.** LiquidIL ships a `json` filter that reference
  does not have; reference treats `json` as an unknown filter and passes input
  through. Either drop the extension or teach the fuzzer to ignore
  LiquidIL-only filters. (~27 findings, rule G2.)
- **Array/empty-array rendering with brackets.** LiquidIL renders `[0]`, `[]`,
  `["0"]` where reference concatenates array elements with no separator. It
  should not inspect arrays on output. (rules G4.)
- **Ruby TypeError on member access of a scalar.** LiquidIL raises
  `no implicit conversion of String into Integer` for `int.title` /
  `int["title"]` / `[expr]` bare-bracket lookups; reference resolves these to
  nil. (rule G5.)
- **`[expr]` parsed as an array literal.** LiquidIL treats a leading
  `[something]` as an array literal; reference treats it as a dynamic
  bracket/variable lookup. (findings 5b81dde6ded5, 4b8bb834b0a5.)
