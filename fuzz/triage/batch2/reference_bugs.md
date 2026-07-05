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
