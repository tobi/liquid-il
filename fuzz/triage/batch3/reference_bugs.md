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
