# LiquidIL Extensibility Design

## Overview

LiquidIL has more pipeline phases than stock Liquid, so extensibility hooks need to be phase-aware. The key insight: **pure filters can be inlined at compile time** for zero dispatch overhead, while impure filters (those needing scope/registers) go through the existing `cff()` path.

## 1. Custom Filters (`register_filter`)

### API

```ruby
ctx = LiquidIL::Context.new

# Standard registration (impure — may access scope)
ctx.register_filter(ShopifyFilters)

# Pure registration (no scope access — compiler can inline)
ctx.register_filter(MathFilters, pure: true)
```

### How it works

**Impure filters** (default):
- Filter module's methods are added to a per-Context filter registry
- At compile time, `cff()` dispatch checks the registry — unknown filters go through `cf()`
- At render time, `cf()` looks up the filter in the scope's filter registry
- Scope/registers accessible via the standard `context` accessor

**Pure filters** (`pure: true`):
- Methods are registered with a "pure" flag
- The structured compiler generates direct `Module.send(:name, input, args...)` calls
- No scope access, no dispatch overhead — same speed as built-in inlined filters
- Example: `CGI.escapeHTML(input)` is pure; `money(input)` that reads locale from registers is impure

### Implementation

```ruby
# In Context
class Context
  def register_filter(mod, pure: false)
    @custom_filters ||= {}
    mod.instance_methods(false).each do |name|
      @custom_filters[name.to_s] = { module: mod, pure: pure }
    end
    # Invalidate ISeq cache since filter availability changed
    StructuredCompiler.class_variable_get(:@@iseq_cache).clear
  end
end

# In StructuredCompiler (expr_to_ruby for :filter)
# If filter is custom+pure → generate ModuleName.name(input, args)
# If filter is custom+impure → generate _H.cf(name, input, args, _S, _F, line)
# If filter is unknown → generate _H.cf(name, input, args, _S, _F, line) (returns input if missing)
```

### Filter dispatch chain at render time

```
1. Built-in filters (Filters module) — checked at compile time, inlined or cff()
2. Custom pure filters — inlined at compile time as direct calls
3. Custom impure filters — dispatched via cf() with scope
4. Unknown filters — return input unchanged (or raise in strict_filters mode)
```

## 2. Custom Tags (`register_tag`)

### Design principle

Tags in LiquidIL are handled at **parse time** — the parser emits IL instructions.
Custom tags need to participate at this level.

### API — Simple tags (no block)

```ruby
ctx.register_tag("section") do |args, builder|
  # args = parsed tag arguments (string)
  # builder = IL::Builder for emitting instructions
  # Can emit WRITE_RAW, CALL_FILTER, etc.
  builder.emit(:WRITE_RAW, "<!-- section: #{args} -->")
end
```

### API — Block tags

```ruby
ctx.register_tag("form", block: true) do |args, builder, body_block|
  # body_block is a proc that emits the body IL when called
  builder.emit(:WRITE_RAW, "<form>")
  body_block.call  # emits body instructions
  builder.emit(:WRITE_RAW, "</form>")
end
```

### Alternative: Runtime-only tags

For tags that are too complex for IL emission, provide a runtime escape hatch:

```ruby
ctx.register_tag("section") do |args, scope, output|
  # Called at render time — args is the raw tag markup
  # scope gives access to variables, registers, file_system
  output << scope.registers[:content_for_section]
end
```

The compiler wraps this in a lambda call — slower than IL but fully flexible.

## 3. Resource Limits

### Design: Compile-time budget insertion

Instead of checking every operation (Liquid's approach), insert checks only where output can grow unboundedly:
- **Loop boundaries**: Check at `FOR_INIT` / start of each iteration
- **Partial calls**: Check before entering partials
- **Not checked**: Individual WRITE_RAW, ASSIGN, filter calls (bounded by template size)

### API

```ruby
ctx = LiquidIL::Context.new(
  resource_limits: {
    output_limit: 1_000_000,      # Max bytes of output (default: unlimited)
    render_score_limit: 100_000,  # Max loop iterations (default: unlimited)
  }
)
```

### Implementation

The structured compiler, when resource limits are configured, inserts:

```ruby
# At loop start (every N iterations, not every one):
if (_x0__ & 0xFF) == 0 && _O.bytesize > __output_limit__
  raise LiquidIL::ResourceLimitError.new("Memory limits exceeded")
end

# At partial entry:
if _O.bytesize > __output_limit__
  raise LiquidIL::ResourceLimitError.new("Memory limits exceeded")
end
```

The `& 0xFF` mask means we check every 256 iterations — amortized O(1) with negligible overhead. For render_score, we increment a counter at each loop iteration and check periodically.

**Key**: When no resource limits are configured, **zero code is generated** — no overhead.

## 4. User-facing Registers

### API

```ruby
ctx = LiquidIL::Context.new(registers: {
  page_type: "product",
  content_for_header: header_html,
})

# Or at render time:
template.render(assigns, registers: { page_type: "collection" })
```

### Implementation

Registers are already stored in `Context` and passed to `Scope`. We just need to:
1. Make them accessible in the scope at render time
2. Let custom filters/tags read them via `scope.registers`
3. Pass render-time registers through to the scope

## 5. strict_variables / strict_filters

### API

```ruby
# At context level
ctx = LiquidIL::Context.new(strict_variables: true, strict_filters: true)

# Or at render level
template.render(assigns, strict_variables: true, strict_filters: true)

# render! shorthand (raises on any error)
template.render!(assigns)
```

### Implementation

**strict_filters**: At compile time, if a filter is not in the built-in or custom registry, emit code that raises `UndefinedFilter` instead of returning input.

**strict_variables**: At render time, `_S.lookup()` raises `UndefinedVariable` when key is not found instead of returning nil. This is a scope flag, not a compiler change.

## Priority Order

1. **register_filter** (pure/impure) — highest impact, enables Shopify filter extensions
2. **User-facing registers** — coupled with impure filters
3. **strict_variables / strict_filters** — needed for development tooling
4. **Resource limits** — needed for production safety
5. **register_tag** — most complex, defer to later
