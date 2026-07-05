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
