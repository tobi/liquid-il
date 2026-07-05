# Reference-liquid bug candidates from differential fuzzing

Divergences where the editorial triage judged reference liquid's behavior an
implementation accident rather than a contract worth specifying — candidates
for upstream Shopify/liquid issues, NOT for liquid-spec donation. Each entry
has a minimal repro and the reasoning. Recorded 2026-07-05 from the triage of
~400 minimized fuzzer findings (full per-batch analysis in fuzz/triage/).

LiquidIL deliberately does NOT conform to these unless noted.

---

# ── From triage batch 1 ──

# Reference-behavior bug candidates — batch1

Divergences where the reference (`liquid` 5.12.0) behavior is judged an
accident/leak rather than a contract worth specifying. These are NOT enshrined
in curated.yml. Each is minimal and reproduced against reference in strict mode.

---

## 1. `cycle` splits its markup on commas *inside* a quoted string

**Repro**

```liquid
{% cycle "a,b,c,d" %}
```

- Reference renders: `""` (empty).
- `{% cycle "hello" %}` renders `hello`, so a lone quoted string works.

**What reference does:** the Cycle tag parses its markup with
`variables_from_string`, which does `markup.split(',')` *before* honoring quotes.
`"a,b,c,d"` is split into the fragments `"a`, `b`, `c`, `d"`; the fragments with
dangling quotes fail to parse and are dropped, the bare fragments (`b`, `c`) are
reinterpreted as **variable lookups** (all undefined → nil), and the first value
rendered is nil → `""`. The quoted string is destroyed by comma-splitting.

**What a reasonable design would do:** treat `"a,b,c,d"` as a single string value
and cycle it (render `a,b,c,d`), consistent with how quoted strings are one token
everywhere else in Liquid (`{% assign x = "a,b" %}`, `{% if x == "a,b" %}`, etc.).

**Why unintentional:** the behavior is inconsistent with the treatment of quoted
strings in every other tag/expression context, it silently mangles a valid
literal, and no template could sensibly rely on "a quoted string with commas
becomes a list of undefined variable references." It is an artifact of splitting
raw markup on commas before tokenizing.

**Affected findings:** `cycle_cb51acd5e73d` (`"a,b,c,d813"` → `""`),
`unless_fa97fb82bfa5` (`"a,b,c,d"` → `""`).

**LiquidIL side:** LiquidIL renders `a,b,c,d813` / `a,b,c,d` (treats it as one
string). That is the *more* defensible output; LiquidIL need not match the
reference mangling. No spec written.

---

## 2. Drops stringify to their Ruby class path (`Liquid::ForloopDrop`)

**Repro**

```liquid
{% for e in (nil..nil) %}{% cycle forloop %}{% endfor %}
{% tablerow r in v %}{% cycle self %}{% endtablerow %}   (v = {name: 'x'})
```

- Reference renders `forloop` as `Liquid::ForloopDrop` and `self` as
  `Liquid::SelfDrop` (also `Liquid::ForloopDrop` from `{{ forloop }}`,
  `{% echo forloop %}`, etc.).

**What reference does:** `Liquid::Drop#to_s` returns `self.class.name`, i.e. the
fully-qualified Ruby class name of the internal drop object.

**What a reasonable design would do:** rendering an internal helper drop
(`forloop`, `tablerowloop`, `self`) as text is meaningless; the output is a Ruby
implementation detail. There is no language-agnostic "right" string here.

**Why unintentional (as a *spec*):** the exact bytes `Liquid::ForloopDrop`
encode Ruby's module path. No non-Ruby implementation can reproduce it without
hard-coding the string `Liquid::`, and no template legitimately depends on
stringifying an internal drop. This is an implementation-detail leak — explicitly
the kind of thing the triage guide says is bug-report material, not a spec.

**Affected findings:** `for_164f3cdd5e24`, `for_5166c65e9871`, `for_68373d6fee17`,
`for_b663bd3915aa`, `for_bef8636ecc18`, `for_cb4674f9c5c9`, `for_dae6f584e107`,
`for_e852473159e2`, `for_53dab3be7b46`, `for_386f38c7d0a2` (SelfDrop),
`unless_a365b216e4b1`.

**LiquidIL side:** LiquidIL emits `ForloopDrop` / `SelfDrop` (unqualified) — also
a leak, just a different one. Neither is a contract. No spec written.

---

## 3. The tokenizer ends a tag at the first `%}` even inside a quoted string

**Repro**

```liquid
{% case nil %}{% when "{% not_a_tag %}" %}{% endcase %}
```

- Reference renders `" %}` and does not raise.

**What reference does:** the top-level tokenizer matches `{%...%}` non-greedily
and is unaware of string quoting. `{% when "{% not_a_tag %}` is taken as the tag
(ending at the first `%}`), leaving the literal text `" %}` and then
`{% endcase %}`. The `when` value parses to an unterminated-string expression
(→ nil), which matches `case nil`, so the trailing text `" %}` renders.

**What a reasonable design would do:** either treat `%}` inside a quoted string as
part of the string, or reject the tag as a syntax error. LiquidIL takes the
latter path (`SyntaxError: Unterminated string`), which is defensible.

**Why unintentional (as a *spec*):** the emitted `" %}` is nonsense output nobody
authors on purpose; enshrining it would freeze a tokenizer limitation as a
contract. It is deeply baked into ruby-liquid and likely won't be fixed, but it
should not become a differential spec — and LiquidIL's stricter tokenization is a
reasonable divergence.

**Affected findings:** `misc_0c7454a2bc39` (parse_disagreement: reference OK,
LiquidIL raises SyntaxError), `unless_2222ff3fa000`, `unless_d34f55f106e1`.

No spec written.

---

## 4. Inline filter-arity error leaks a Ruby `ArgumentError` message + line prefix mismatch

**Repro**

```liquid
{{ nil | divided_by }}
```

- Reference (plain render) embeds: `Liquid error: wrong number of arguments (given 1, expected 2)`
- LiquidIL embeds: `Liquid error (line 1): wrong number of arguments (given 1, expected 2)`

**Two separable issues:**
1. The message body `wrong number of arguments (given 1, expected 2)` is a raw
   Ruby `ArgumentError` from invoking the `divided_by` filter method with the
   wrong arity — an implementation leak, not a Liquid-authored diagnostic.
2. The `Liquid error` prefix differs: reference omits `(line N)` here, LiquidIL
   adds `(line 1)`.

**Why not a spec:** the message is a Ruby-internals leak (arity counting of a
Ruby method), so its exact text is not a portable contract; and the line-number
prefix is a formatting divergence, not a semantic one.

**Affected finding:** `misc_ac945a73e868`.

**LiquidIL side:** worth aligning the `Liquid error` prefix format with reference
for parity, but the message itself should not be treated as a spec.

# ── From triage batch 2 ──

# Reference-behavior bug candidates — fuzz_if_* / fuzz_case_* triage (batch2)

These are reference (Shopify/liquid 5.12.0) behaviors I judge to be accidents
or incoherent artifacts rather than contracts worth enshrining. They are NOT in
`curated.yml`. Each is a candidate ruby-liquid bug report.

---

## 1. Tokenizer splits `{% ... %}` inside a quoted argument, leaking partial markup as literal text

**Minimal repro** (error_mode: strict):

```liquid
{% case nil %}{% when "{% not_a_tag %}" %}{% endcase %}
```

renders `" %}` (a literal double-quote, space, `%}`).

```liquid
{% case nil %}{% when [[["{% not_a_tag %}"]]] %}{% endcase %}
```

renders `"]]] %}`.

**What reference does:** The block tokenizer matches tag bodies with a
non-greedy `.*?` up to the first `%}`. A `%}` that appears *inside a quoted
string argument* therefore terminates the tag early. The remainder of the
intended tag (`" %}`) falls out of the tag and is emitted as ordinary template
text. No error is raised; the leaked fragment is silently rendered.

**What a reasonable design would do:** Either (a) treat `%}` inside a quoted
string as part of the string (quote-aware tokenizing), or (b) raise a syntax
error for the malformed tag. Emitting a slice of the source as output text is
the worst of both — it neither parses the tag nor reports a problem, and the
output is a meaningless fragment of the template's own syntax.

**Why I judge it unintentional:** The output is a raw shard of Liquid markup
(`"]]] %}`) that no author could intend or rely on; it is a direct artifact of
a regex tokenizer that is not string-aware. It is inconsistent with strict mode
elsewhere, which raises on malformed tags. This is a known structural
limitation of the regex tokenizer rather than a designed behavior.

**Caveat:** This is a longstanding, widely-known limitation (you cannot put
`%}` inside a tag), so it is arguably "documented folklore." I still flag it
because the *observable result* — leaking template source as rendered text with
no error — is user-hostile and belongs in the parser/tokenizer domain, not in
the if/case semantics I own.

**Affected finding hashes:** `b59c8e9f0727`, `124cfed626ce`, `fe7e6792d599`
(case class). LiquidIL diverges by rendering empty instead of the leaked
fragment — LiquidIL is arguably *more* correct here, but neither matches a clean
design.

---

## Borderline (documented-but-questionable, spec'd rather than filed)

### Blank-tag render-error suppression

`{% if 5 > "x" %}{% endif %}` (blank body) renders `""` while
`{% if 5 > "x" %}hit{% endif %}` renders the `Liquid error (...)` text. Identical
erroring code produces different output based solely on whether the tag body
happens to be blank. This is inconsistent on its face, BUT the ruby-liquid
source carries an explicit `# conditional for backwards compatibility` comment
(`BlockBody.rescue_render_node`), so it is a deliberate, longstanding
compatibility choice — the kind of quirk liquid-spec documents rather than
reports. I therefore SPEC it
(`blank_control_flow_tag_swallows_render_errors`) instead of filing it, but note
it here as a design wart worth revisiting upstream.

---

## Not bugs (reference is correct; LiquidIL should fix its side)

The large "comparison of String with String" and "Unknown operator ...\"]]"
clusters are **LiquidIL** defects, not reference bugs:

- **String-vs-string ordering:** reference correctly compares two strings
  lexicographically; LiquidIL wrongly raises "comparison of String with String
  failed". (Findings `494b2f01e699`, `ff2fa8f35f5d`, `29065d4d0bdd`,
  `41f6f2069019`, `4823586a55c1`, `b4dd664923db`.) Captured positively by
  `strings_compare_lexicographically`.

- **Bracket expressions (`["x"]`, `[[...]]`) in conditions:** Liquid has no
  array-literal syntax; in strict/lax mode `[...]` is a bracket variable lookup
  that resolves to nil (and strict2 rejects it outright with "Bare bracket
  access is not allowed", already covered by
  `liquid_ruby/bare_bracket_self.yml`). Reference silently yields nil/false;
  LiquidIL emits a garbage `Unknown operator World!535"]]` message that matches
  neither the strict nil-lookup nor the strict2 parse error. LiquidIL should
  align with one of the two reference modes. (Findings `1c7ed1fbe589`,
  `2d18c2ff31ca`, `4387895b2113`, `462d6ffd551d`, `5d3730425850`,
  `6b7c785999bb`, `7c1f9aa970f2`, `a0a158957065`, `a0e4524f111f`,
  `bf1960e5d46f`, `cb0d2f8ab7b6`, `e3ce6baf6527`, `f0f42e3e9e82`,
  `952922d52dec`.) Not spec'd here — the behavior is being removed upstream via
  strict2.

# ── From triage batch 3 ──

# Reference-liquid bug candidates — batch3

Divergences where reference `liquid` behavior looks like an accident of its Ruby
implementation rather than a contract worth enshrining. These are NOT added to
the spec suite.

---

## 1. `cycle` silently drops output when its value is a quoted string containing a comma

**Minimal repro**

```liquid
{% cycle "Hello, World!92" %}
```

**Reference (strict, gem in this bundle):** renders `""` (nothing).
`{% cycle "a, b" %}` also renders `""`.

**Sibling that works:** `{% cycle "a", "b" %}` renders `a`. And a comma-free
string renders fine: `{% cycle "Hello World" %}` -> `Hello World`.

**What a reasonable design would do:** a single quoted-string argument is one
literal value; its internal comma is just a character. The tag should output the
string (`Hello, World!92`).

**Why unintentional:** the comma inside the quoted literal is being consumed by
cycle's argument-list splitting (the same comma that separates real cycle
values), leaving a value that renders to nothing. A quoted string's contents
must not participate in argument tokenization. The inconsistency between
`cycle "a, b"` (empty) and `cycle "a", "b"` (works) and `cycle "ab"` (works) is
the tell: the only variable is the presence of a comma *inside a quote*.

**Affected findings:** `fuzz_id_66e979858690`.

**LiquidIL side:** LiquidIL renders the string (`Hello, World!92`), i.e. it does
the sensible thing. It should NOT be changed to match this reference accident.

---

## 2. (Minor) filter arity errors leak Ruby's `ArgumentError` wording

**Minimal repro**

```liquid
{{ 5 | at_least }}
```

**Reference:** `Liquid error: wrong number of arguments (given 1, expected 2)`.
Same for `{{ nil | times }}`, `{{ nil | divided_by }}`, `{{ nil | split }}`.

**Why it is borderline:** `wrong number of arguments (given 1, expected 2)` is
Ruby's raw `ArgumentError` phrasing surfaced verbatim. It exposes the Ruby
method arity (input counts as argument 1) rather than a filter-oriented message
like "at_least requires 1 argument". This is in the same family as the
`no implicit conversion of String into Integer` leaks that QUIRKS treats as
implementation detail, not contract.

**Why it is only "minor":** unlike case 1 this is not silently wrong, just an
ugly message, and in every fuzzer finding it occurs inside `{% assign %}` where
it is swallowed entirely (see `assign_swallows_filter_error` spec), so no page
ever displays it. Not worth a spec; flagged only so the message is not treated
as a stable contract by implementers.

**Affected findings (all via assign, output swallowed):**
`fuzz_at_least_595133b4948f`, `fuzz_times_29f9eab41cc1`,
`fuzz_divided_by_f3646009f45c`. Direct-output leak visible in
`fuzz_round_f29cf61ff444` (`nil | split` has no argument).

# ── From triage batch 4 ──

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
