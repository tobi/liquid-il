# LiquidIL Extensibility

## Custom Filters (`register_filter`)

```ruby
ctx = LiquidIL::Context.new

# Pure filters — no scope access, compiler can inline for zero dispatch overhead
module MathFilters
  def double(input)
    (input.to_f * 2).to_s
  end
end
ctx.register_filter(MathFilters, pure: true)

# Impure filters — have scope access for reads, standard dispatch path
module ShopifyFilters
  def money(input, currency = "USD")
    "$#{"%.2f" % input.to_f} #{currency}"
  end
end
ctx.register_filter(ShopifyFilters)
```

Pure filters generate direct method calls in compiled code. Impure filters go through `ccf()` dispatch with scope access. Both participate in `strict_filters` checks.

## Custom Tags (`register_tag`)

```ruby
ctx = LiquidIL::Context.new

# Passthrough — body is evaluated as normal Liquid
ctx.register_tag("highlight", mode: :passthrough)
# {% highlight %}{{ name }}{% endhighlight %} → evaluates {{ name }}

# With wrapping output
ctx.register_tag("box", mode: :passthrough,
  setup: ->(args, builder) { builder.write_raw("[") },
  teardown: ->(args, builder) { builder.write_raw("]") })
# {% box %}content{% endbox %} → [content]

# Discard — body is silently skipped
ctx.register_tag("schema", mode: :discard)
# {% schema %}...{% endschema %} → (empty)

# Raw — body captured as literal text, no evaluation
ctx.register_tag("verbatim", mode: :raw)
# {% verbatim %}{{ x }}{% endverbatim %} → {{ x }}

# Custom end tag name
ctx.register_tag("section", end_tag: "endsection", mode: :passthrough)
```

**Note:** Tags are registered globally (they affect parsing). For per-request isolation, use separate processes.

## Strict Modes

```ruby
# Raise on undefined filters
ctx = LiquidIL::Context.new(strict_filters: true)
ctx.parse("{{ x | typo }}").render!("x" => 1)
# => raises LiquidIL::UndefinedFilter

# Raise on undefined variables
ctx = LiquidIL::Context.new(strict_variables: true)
ctx.parse("{{ missing }}").render!({})
# => raises LiquidIL::UndefinedVariable

# Per-render overrides
template.render!(assigns, strict_variables: true, strict_filters: true)
```

## Error Mode (Parse-time)

```ruby
# :lax (default) — skip unknown tags silently
ctx = LiquidIL::Context.new(error_mode: :lax)

# :strict — raise on unknown tags
ctx = LiquidIL::Context.new(error_mode: :strict)
ctx.parse("{% bad_tag %}")  # => raises SyntaxError

# :warn — collect warnings, continue parsing
ctx = LiquidIL::Context.new(error_mode: :warn)
t = ctx.parse("{% unknown %}")
t.warnings  # => ["Unknown tag 'unknown'"]
```

## Resource Limits

```ruby
ctx = LiquidIL::Context.new(resource_limits: {
  output_limit: 1_000_000,       # Max output bytes
  render_score_limit: 100_000,   # Max total loop iterations
})
```

Checks are inserted at loop boundaries and partial entry points only. **When no limits are configured, zero checking code is generated** — no overhead.

## Registers

```ruby
# Context-level (set once)
ctx = LiquidIL::Context.new(registers: { page_type: "product" })

# Render-time (merged with context registers)
template.render(assigns, registers: { content_for_header: html })
```

Accessible to custom filters and tags via `scope.user_registers`.

## Strict Rendering (`render!`)

```ruby
template.render!(assigns)  # Raises on any error instead of inline rendering
template.render!(assigns, strict_variables: true)  # Combine with strict modes
```

## Security Model

LiquidIL prevents templates from accessing dangerous Ruby methods. The security is based on **whitelisting**, not blacklisting.

### Drops

`LiquidIL::Drop` uses the same security model as `Liquid::Drop`:

```ruby
class ProductDrop < LiquidIL::Drop
  def name; @name; end    # ✅ Accessible from templates
  def price; @price; end  # ✅ Accessible from templates
end

# In template:
# {{ product.name }}           → "Widget"
# {{ product.class }}          → "" (blocked)
# {{ product.send }}           → "" (blocked)
# {{ product.instance_eval }}  → "" (blocked)
```

Only methods defined on the **subclass** are accessible. Everything from Object, Kernel, and the Drop base class is blacklisted: `send`, `__send__`, `public_send`, `class`, `object_id`, `instance_eval`, `instance_exec`, `instance_variable_get`, `methods`, `respond_to?`, `freeze`, `dup`, `clone`, `extend`, `define_singleton_method`, etc.

### Liquid::Drop Compatibility

Existing `Liquid::Drop` subclasses work unchanged — our lookup code detects `invoke_drop` and routes through Liquid's own security machinery:

```ruby
class LegacyDrop < Liquid::Drop
  def name; "works"; end
end
LiquidIL::Template.parse("{{ d.name }}").render("d" => LegacyDrop.new)
# => "works"
```

### to_liquid Protocol

Objects can implement `to_liquid` to control their template representation:

```ruby
class Product
  def to_liquid
    { "name" => @name, "price" => @price }
  end
end
```

`to_liquid` is called during property lookup. Objects without `to_liquid` that aren't Hash/Array/String/Numeric return nil for property access.

### Type-aware Security

The compiler knows at parse time whether an expression originates from a **literal** (safe) or a **variable** (untrusted). Literals like `{{ "hello" | upcase }}` are constant-folded at compile time and never touch the security machinery. Only variable lookups (`{{ product.name }}`) go through the Drop security checks.
