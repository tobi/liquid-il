# Current Focus: YJIT-Friendly Structured Compiler

## Goal

The `liquid_il_structured` compiler generates **native Ruby control flow** instead of a state machine, enabling YJIT to optimize the generated code effectively.

### The Problem with State Machine Code

The current `ruby_compiler.rb` generates state machine code that YJIT cannot optimize well:

```ruby
# What we DON'T want (state machine - defeats YJIT)
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

**Why this is bad for YJIT:**
- Dynamic dispatch via `case __pc__` - unpredictable branches
- Loop with variable iteration count - can't specialize
- Indirect jumps via `__pc__ = N` - defeats inlining
- No stable code shape - YJIT can't learn patterns

### The Solution: Native Control Flow

The structured compiler generates code that looks like hand-written Ruby:

```ruby
# What we DO want (native control flow - YJIT friendly)
proc do |__scope__|
  __output__ = String.new

  __output__ << "Hello "

  if __is_truthy__(__scope__.lookup("show_name"))
    __output__ << __scope__.lookup("name").to_s
  end

  __output__ << "!"
  __output__
end
```

**Why this is good for YJIT:**
- Straight-line code with clear branch targets
- Native `if/else` - predictable branch patterns
- No loop for linear code - direct execution
- Stable code shape - YJIT can inline and specialize

### For Loops: Native `.each` vs State Machine

**DON'T want (state machine for loop):**
```ruby
when 5
  __forloop_idx__ += 1
  if __forloop_idx__ >= __forloop_len__
    __pc__ = 8  # exit loop
  else
    __pc__ = 6  # loop body
  end
when 6
  __scope__.set("item", __forloop_coll__[__forloop_idx__])
  __output__ << __scope__.lookup("item").to_s
  __pc__ = 5  # back to loop check
```

**DO want (native Ruby each):**
```ruby
__coll__ = __to_iterable__(__scope__.lookup("items"))
unless __coll__.empty?
  __scope__.push_scope
  __coll__.each_with_index do |__item__, __idx__|
    __scope__.set_local("item", __item__)
    __output__ << __item__.to_s
  end
  __scope__.pop_scope
end
```

### Conditionals: Native `if/elsif/else`

**DON'T want:**
```ruby
when 2
  if __is_truthy__(__scope__.lookup("a"))
    __pc__ = 3
  else
    __pc__ = 4
  end
when 3
  __output__ << "A"
  __pc__ = 7
when 4
  if __is_truthy__(__scope__.lookup("b"))
    __pc__ = 5
  else
    __pc__ = 6
  end
# ... more cases
```

**DO want:**
```ruby
if __is_truthy__(__scope__.lookup("a"))
  __output__ << "A"
elsif __is_truthy__(__scope__.lookup("b"))
  __output__ << "B"
else
  __output__ << "C"
end
```

---

## Current Status

**Benchmark results (render time):**
| Adapter | vs liquid_ruby |
|---------|----------------|
| `liquid_il_optimized_compiled` | 1.85x faster |
| `liquid_il_compiled` | 1.45x faster |
| `liquid_il_structured` | **1.64x slower** |

The structured compiler is currently **slower** than even the interpreter. This needs investigation - either the code generation has overhead issues, or the current implementation is missing optimizations.

---

## TODO

### Phase 1: Get Basic Specs to Pass
- [ ] Run `bundle exec liquid-spec run spec/liquid_il_structured.rb` and identify failures
- [ ] Fix failing basic tests (variables, filters, simple if/else)
- [ ] Fix for loop iteration semantics
- [ ] Ensure forloop drop (index, first, last, etc.) works correctly

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
- [ ] Structured compiler is faster than `liquid_ruby` for render
- [ ] Structured compiler shows better YJIT speedup than state machine compiler
- [ ] Render time within 10% of `liquid_il_optimized_compiled`

---

## Key Files

- `lib/liquid_il/compiler/structured.rb` - The structured code generator
- `lib/liquid_il/compiler/ruby.rb` - The state machine compiler (for comparison)
- `spec/liquid_il_structured.rb` - The liquid-spec adapter
- `docs/structured_ruby_prd.md` - Original PRD for this work
