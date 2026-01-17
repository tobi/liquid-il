# Current Focus: YJIT-Friendly Structured Compiler

## Goal

The `liquid_il_structured` compiler generates **clean, readable Ruby** with native control flow. The generated code should look like something a Ruby developer would write by hand.

### Design Principles

1. **Readable Ruby** - Generated code is a readable artifact, not just an execution target
2. **Native control flow** - Use `if/else`, `each`, `case/when` instead of state machines
3. **Minimal ceremony** - No unnecessary prefixes, wrappers, or abstractions
4. **Ruby semantics** - Use Ruby's truthiness directly (no `__is_truthy__` wrapper)
5. **YJIT-friendly** - Straightline code that YJIT can optimize

### The Problem: State Machine Code

The current `ruby_compiler.rb` generates state machine code:

```ruby
# DON'T want: State machine with ceremony
proc do |__scope__|
  __output__ = String.new
  __pc__ = 0
  while true
    case __pc__
    when 0
      __output__ << "Hello "
      __pc__ = 1
    when 1
      if __is_truthy__(__scope__.lookup("show_name"))
        __pc__ = 2
      else
        __pc__ = 3
      end
    when 2
      __output__ << __scope__.lookup("name").to_s
      __pc__ = 3
    when 3
      __output__ << "!"
      return __output__
    end
  end
end
```

**Problems:**
- Unreadable - no one would write this by hand
- `__is_truthy__` wrapper when Ruby's truthiness is the same as Liquid's
- `__scope__.lookup("name")` instead of `scope["name"]`
- State machine defeats YJIT optimization

### The Solution: Clean Ruby

**Liquid template:**
```liquid
Hello {% if show_name %}{{ name }}{% endif %}!
```

**DO want: Readable Ruby**
```ruby
proc do |scope|
  output = +""
  output << "Hello "
  if scope["show_name"]
    output << scope["name"].to_s
  end
  output << "!"
  output
end
```

This is Ruby code you'd be proud to show someone. It reads naturally and does exactly what the template says.

### For Loops

**Liquid:**
```liquid
{% for item in items %}{{ item }}{% endfor %}
```

**DO want:**
```ruby
items = scope["items"]
items.each do |item|
  output << item.to_s
end
```

**With forloop drop (when used):**
```ruby
items = scope["items"]
items.each_with_index do |item, idx|
  forloop = ForloopDrop.new(items.size, idx)
  output << item.to_s
  output << forloop.index.to_s  # only if template uses forloop.index
end
```

### Conditionals

**Liquid:**
```liquid
{% if a %}A{% elsif b %}B{% else %}C{% endif %}
```

**DO want:**
```ruby
if scope["a"]
  output << "A"
elsif scope["b"]
  output << "B"
else
  output << "C"
end
```

### Filters

**Liquid:**
```liquid
{{ name | upcase | truncate: 10 }}
```

**DO want:**
```ruby
output << filters.truncate(filters.upcase(scope["name"]), 10).to_s
```

### Key Simplifications

| Instead of | Use |
|------------|-----|
| `__scope__.lookup("name")` | `scope["name"]` |
| `__is_truthy__(x)` | `x` (Ruby's truthiness) |
| `__output__` | `output` |
| `String.new(capacity: 8192)` | `+""` |
| `__to_iterable__.call(x)` | Direct iteration |

### Why Ruby Truthiness Works

Liquid's truthiness rules match Ruby's exactly:
- `false` → falsy
- `nil` → falsy
- Everything else → truthy (including `0`, `""`, `[]`)

So `if scope["show_name"]` does exactly what `{% if show_name %}` does.

---

## Current Status

**Spec results:** 4422 passed, 10 failed (edge cases)

**Benchmark results (render time):**
| Adapter | vs liquid_ruby |
|---------|----------------|
| `liquid_il_optimized_compiled` | 1.85x faster |
| `liquid_il_compiled` | 1.45x faster |
| `liquid_il_structured` | **1.64x slower** |

The structured compiler is currently **slower** than even the interpreter. This needs investigation - either the code generation has overhead issues, or the current implementation is missing optimizations.

**Known Issues (10 failing specs):**
- Dynamic range type validation (float bounds)
- Filter error handling (should be silent)
- Cycle with 0 choices
- For loop limit/offset validation
- Forloop reset after nested loop
- gsub escape sequences
- Integer.size

---

## TODO

### Phase 1: Get Basic Specs to Pass
- [x] Run `bundle exec liquid-spec run spec/liquid_il_structured.rb` and identify failures
- [x] Fix failing basic tests (variables, filters, simple if/else)
- [x] Fix for loop iteration semantics
- [x] Ensure forloop drop (index, first, last, etc.) works correctly
- [x] Fix heredoc escaping (regex patterns, string interpolation)
- [x] Fix comparison logic to match VM behavior
- [x] Fix infinite loop when optimizer creates jump cycles

### Phase 2: Get All Specs to Pass
- [ ] Implement missing features:
  - [ ] Break/continue support
  - [ ] Tablerow tag
  - [ ] Render/include partials
  - [ ] Capture blocks
  - [ ] Case/when statements
- [ ] Handle edge cases in nested control flow
- [ ] Match error handling behavior with other adapters

### Phase 3: Profile and Identify Bottlenecks
- [ ] Run stackprof on structured compiler render path
- [ ] Identify hot paths and allocation sources
- [ ] Compare generated code size vs ruby_compiler
- [ ] Check if helper lambdas are being inlined

### Phase 4: Optimize
- [ ] Reduce allocations in generated code
- [ ] Inline small helper calls where possible
- [ ] Eliminate unnecessary scope push/pop
- [ ] Consider loop unrolling for small static collections
- [ ] Review string building strategy

### Phase 5: YJIT Benchmarking
- [ ] Run `rake bench` without YJIT (baseline)
- [ ] Run `RUBY_YJIT_ENABLE=1 rake bench` with YJIT
- [ ] Compare YJIT speedup for each adapter:
  - State machine (`liquid_il_compiled`) - expect modest gains
  - Structured (`liquid_il_structured`) - expect significant gains
- [ ] Document YJIT stats (compiled methods, exits, etc.)

### Success Criteria
- [ ] All specs pass for `liquid_il_structured`
- [ ] **Generated code is readable Ruby** - looks like hand-written code
- [ ] Structured compiler is faster than `liquid_ruby` for render
- [ ] Structured compiler shows better YJIT speedup than state machine compiler
- [ ] Render time within 10% of `liquid_il_optimized_compiled`

---

## Key Files

- `lib/liquid_il/structured_compiler.rb` - The structured code generator
- `lib/liquid_il/ruby_compiler.rb` - The state machine compiler (for comparison)
- `spec/liquid_il_structured.rb` - The liquid-spec adapter
- `docs/structured_ruby_prd.md` - Original PRD for this work

## Implementation Notes

The current implementation uses verbose naming (`__scope__`, `__output__`, etc.) and helper lambdas.
To achieve the clean Ruby vision, we need to:

1. **Make Scope subscriptable** - Implement `scope[name]` as alias for `scope.lookup(name)`
2. **Use Ruby truthiness** - For most cases, `if scope["x"]` works directly
3. **Handle edge cases efficiently** - Drops with `to_liquid_value`, EmptyLiteral, BlankLiteral
4. **Clean variable names** - Use `output`, `scope`, `filters` not double-underscore prefixed names
