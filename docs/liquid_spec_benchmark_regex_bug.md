# liquid-spec benchmark regex bug

## Summary

4 benchmark specs in `specs/benchmarks/` fail for **all** adapters (including `liquid_ruby`) because their `expected_pattern` regexes use `.*` to match across HTML lines, but don't include the `(?m)` multiline flag. Ruby's `Regexp.new(pattern)` compiles `.*` to match any character **except** newline by default.

The storefront benchmarks (added later) already use `(?m)` correctly and pass.

## Affected specs

| Spec | File | Bug |
|------|------|-----|
| `bench_online_store_page` | `complex.yml` | Missing `(?m)` |
| `bench_order_confirmation` | `complex.yml` | Missing `(?m)` |
| `bench_product_grid` | `loops.yml` | Missing `(?m)` |
| `bench_collection_with_filters` | `complex.yml` | Missing `(?m)` **AND** pattern expects `pagination` but `total_pages` is nil in environment so the pagination section never renders |

## Reproduction (plain Ruby, no Liquid)

```ruby
# All keywords are present in the rendered output, on separate lines:
output = <<~HTML
  <title>Premium Wireless Earbuds Pro | TechGear Store</title>
  <button class="add-to-cart">Add to Cart - $149</button>
  <h2>You May Also Like</h2>
HTML

pattern = "TechGear Store.*Add to Cart.*You May Also Like"

# BUG: .* doesn't cross newlines without MULTILINE
Regexp.new(pattern).match?(output)                       #=> false
Regexp.new(pattern, Regexp::MULTILINE).match?(output)    #=> true

# Equivalent: embed (?m) in the pattern string itself
Regexp.new("(?m)" + pattern).match?(output)              #=> true
```

## How liquid-spec applies the pattern

In `lib/liquid/spec/lazy_spec.rb`:

```ruby
def expected_pattern_regex
  return unless expected_pattern
  expected_pattern.is_a?(Regexp) ? expected_pattern : Regexp.new(expected_pattern)
end
```

`Regexp.new(string)` with no flags → `.*` does not match `\n`.

## Fix

### Option A: Add `(?m)` to each pattern (minimal, spec-level)

```yaml
# complex.yml
- name: bench_online_store_page
  expected_pattern: "(?m)TechGear Store.*Premium Wireless Earbuds.*Add to Cart.*You May Also Like"
```

### Option B: Apply `Regexp::MULTILINE` by default for `expected_pattern` (framework-level)

```ruby
def expected_pattern_regex
  return unless expected_pattern
  expected_pattern.is_a?(Regexp) ? expected_pattern : Regexp.new(expected_pattern, Regexp::MULTILINE)
end
```

This is the better fix — benchmark templates are always multi-line HTML, so `.*` should always be able to cross newlines. Specs that need single-line matching can still use `[^\n]*` explicitly.

### Additional fix for `bench_collection_with_filters`

The environment needs `total_pages` set to a value > 1 for the pagination section to render:

```yaml
environment:
  total_pages: 3    # was: nil (missing)
  current_page: 1
```

## Proof

See `test/liquid_spec_regex_bug_test.rb` for a self-contained minitest suite that reproduces all 4 bugs without involving Liquid.

Both `liquid_ruby` and `liquid_il` adapters fail these 4 specs identically.
