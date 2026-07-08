# liquid-spec 2.0.0 Spec Bugs

Tracking specs in the upstream liquid-spec gem that have incorrect expected
values or other issues. These are NOT bugs in LiquidIL — they are bugs in
the spec suite itself. Each entry is confirmed by showing reference liquid
(Shopify/liquid) produces the same output as LiquidIL, contradicting the
spec's expected value.

Flagged in the adapter via `config.known_failures` so they don't count as
real failures but are still tracked.

## 1. lax_filter_booleandrop_first_last_size

- **File:** `specs/liquid_ruby_lax/variable_type_filters.yml:500`
- **Complexity:** 520
- **Suite:** liquid_ruby_lax
- **Status:** Flagged as known_failure

### Problem

The spec expects `BooleanDrop` (with `value: true`) to render as `"Yay"`:

```yaml
template: |
  drop value:{{- d }}
  ...
environment:
  d:
    instantiate:BooleanDrop:
      value: true
expected: |
  drop value:Yay
  ...
```

But liquid-spec 2.0.0's `standard_drops.rb` is loaded AFTER the legacy
`liquid_ruby.rb` drop registrations, so `instantiate:BooleanDrop` now
creates a `StandardBooleanDrop` (not the old `BooleanDrop`).

- `StandardBooleanDrop#to_s` returns `"true"` / `"false"`
- Old `BooleanDrop#to_s` returned `"Yay"` / `"Nay"`

The spec's expected value (`"Yay"`) reflects the old behavior, but the
drop class that is actually instantiated (`StandardBooleanDrop`) produces
`"true"`.

### Confirmation

Reference liquid (Shopify/liquid) also renders `"true"`:

```ruby
require "liquid"
require "liquid/spec/deps/liquid_ruby"
f = Liquid::Spec::ClassRegistry.all["BooleanDrop"]
d = f.call({"value" => true})
Liquid::Template.parse("{{ d }}").render({"d" => d})
# => "true"
```

Both reference liquid and LiquidIL produce `"true"`, confirming the spec's
expected `"Yay"` is stale.

### Fix needed upstream

The `liquid_ruby_lax/variable_type_filters.yml` spec should be updated to
expect `"true"` instead of `"Yay"` (and `"false"` instead of `"Nay"` for
the `value: false` case), matching the `StandardBooleanDrop` behavior that
`basics/drops.yml` already expects.

### Impact on complexity level

This known failure sits at complexity 520, which blocks the complexity
level at 510 (the highest level below 520 where all specs pass). Until
this spec is fixed upstream, the complexity level cannot reach 1000.
