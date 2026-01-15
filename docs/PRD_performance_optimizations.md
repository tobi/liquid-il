# PRD: LiquidIL Performance Optimizations

## Executive Summary

Comprehensive profiling of the LiquidIL Ruby compiler and generated code has identified significant optimization opportunities in both compile-time and render-time performance. This document outlines actionable improvements based on real profiling data.

## Profiling Results Summary

### Compile-Time Performance

| Template Type | Parse Time | Ruby Compile | Parse Allocs | Compile Allocs |
|--------------|-----------|--------------|--------------|----------------|
| simple_output | 0.023ms | 0.03ms | 79 | 108 |
| filter_chain | 0.042ms | 0.045ms | 109 | 112 |
| simple_loop | 0.094ms | 0.1ms | 208 | 258 |
| nested_loops | 0.234ms | 0.197ms | 442 | 487 |
| complex_ecommerce | 0.378ms | 0.269ms | 688 | 657 |

**Top compile-time hot spots (StackProf):**
1. `Kernel#eval` - 13.4% (final Ruby compilation)
2. `find_max_temp_index` - 6.3% (IL optimization pass)
3. `Array#each` - 4.1% (general iteration)
4. `control_flow_boundary?` - 3.8% (IL optimization)
5. `const_value` - 3.7% (constant folding)
6. `build_basic_blocks` - 3.3% (CFG construction)
7. `generate_state_machine` - 2.6% (code generation)

**Memory allocation by file (compile-time):**
1. `ruby_compiler.rb` - 3.69MB (62.8%)
2. `compiler.rb` - 785KB (13.4%)
3. `lexer.rb` - 498KB (8.5%)
4. `il.rb` - 401KB (6.8%)
5. `parser.rb` - 364KB (6.2%)

### Render-Time Performance

| Template Type | Render Time | Render Allocs |
|--------------|------------|---------------|
| simple_output | 0.003ms | 21 |
| filter_chain | 0.012ms | 38 |
| simple_loop | 0.015ms | 45 |
| nested_loops | 0.095ms | 101 |
| complex_ecommerce | 0.021ms | 61 |

**Top render-time hot spots (StackProf):**
1. `eval_ruby` module entry - 23.5%
2. `__lookup_property__` - 11.6%
3. `Scope#lookup` - 11.3%
4. GC sweeping - 5.9%
5. `__is_truthy__` - 4.1%
6. `Scope#initialize` - 3.8%
7. `Utils.output_string` - 3.6%

**Memory allocation by source (render-time):**
1. Generated Ruby code - 8.87MB (73.5%)
2. `context.rb` - 1.64MB (13.6%)
3. `filters.rb` - 360KB (3.0%)
4. `utils.rb` - 360KB (3.0%)

---

## Optimization Opportunities

### Priority 1: Generated Code Quality (High Impact)

#### 1.1 Eliminate State Machine for Simple Templates

**Problem:** Even simple templates like `{{ name }}` generate a full state machine with `while true; case __pc__; when 0; ...` pattern, adding overhead for the common case.

**Current generated code:**
```ruby
__pc__ = 0
while true
  case __pc__
  when 0
    __output__ << "Hello "
    __output__ << (__v__ = __scope__.lookup("name"); ...)
    break
  else
    break
  end
end
```

**Proposed improvement:**
```ruby
__output__ << "Hello "
__output__ << (__v__ = __scope__.lookup("name"); ...)
```

**Impact:** Eliminate dispatch overhead for ~60% of templates (those without control flow).

---

#### 1.2 Inline Scope Lookups for Known Variables

**Problem:** Every variable access goes through `__scope__.lookup(name)` which:
1. Converts key to string if needed
2. Checks `@assigned_vars` hash
3. Checks `@registers["counters"]`
4. Iterates through scope chain

**Profile evidence:** `Scope#lookup` is 11.3% of render time.

**Proposed improvement:** For variables accessed multiple times in a block, hoist the lookup:
```ruby
# Before (current)
__output__ << (__v__ = __lookup_property__(__scope__.lookup("product"), "title"); ...)
__output__ << (__v__ = __lookup_property__(__scope__.lookup("product"), "price"); ...)

# After (optimized)
__product__ = __scope__.lookup("product")
__output__ << (__v__ = __lookup_property__(__product__, "title"); ...)
__output__ << (__v__ = __lookup_property__(__product__, "price"); ...)
```

**Note:** This is partially implemented via temp variables (`__t0__`), but not consistently applied.

---

#### 1.3 Specialize Output for Common Types

**Problem:** Every output goes through `LiquidIL::Utils.output_string(value)` which does type dispatch even for strings.

**Profile evidence:** `Utils.output_string` is 3.6% of render time, allocating strings per call.

**Proposed improvement:** Generate specialized output code based on IL analysis:
```ruby
# For paths known to return strings (e.g., .title property)
__output__ << __lookup_property__(__product__, "title").to_s

# For filters that return strings (escape, upcase, etc.)
__output__ << __call_filter__("escape", value, [], ...)  # Filter returns string directly

# Only use output_string for unknown types
__output__ << LiquidIL::Utils.output_string(complex_expr)
```

---

#### 1.4 Skip ErrorMarker Check for Safe Operations

**Problem:** Every output expression includes `__v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : ...` even for operations that can't produce errors.

**Current code:**
```ruby
__output__ << (__v__ = __lookup_property__(__t0__, "title"); __v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : LiquidIL::Utils.output_string(__v__))
```

**Proposed improvement:** Track which operations can produce errors at compile time:
```ruby
# Property lookups never produce ErrorMarker
__output__ << LiquidIL::Utils.output_string(__lookup_property__(__t0__, "title"))

# Filter calls can produce ErrorMarker - keep the check
__output__ << (__v__ = __call_filter__(...); __v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : LiquidIL::Utils.output_string(__v__))
```

---

### Priority 2: Scope and Context Optimizations (Medium Impact)

#### 2.1 Fast Path for Simple Variable Lookup

**Problem:** `Scope#lookup` always checks counters and assigned_vars even when the variable is a simple hash key.

**Proposed improvement:**
```ruby
def lookup(key)
  key = key.to_s unless key.is_a?(String)

  # Fast path: check first scope directly (covers 80%+ of cases)
  first_scope = @scopes[0]
  if first_scope.key?(key)
    return first_scope[key] unless @assigned_vars[key] || @registers["counters"]&.key?(key)
  end

  # Slow path: full lookup
  lookup_slow(key)
end
```

---

#### 2.2 Eliminate Scope Initialization Overhead

**Problem:** `Scope#initialize` allocates multiple hashes and arrays per render.

**Profile evidence:** `Scope#initialize` is 3.8% of render time.

**Proposed improvement:** Use object pooling or lazy initialization:
```ruby
def initialize(assigns, ...)
  @static_environments = assigns  # Don't dup if not needed
  @scopes = [assigns]  # Reuse instead of stringify_keys
  # Lazy init for rarely-used features
  @interrupts = nil  # -> @interrupts ||= []
  @assigned_vars = nil  # -> @assigned_vars ||= {}
end
```

---

#### 2.3 Cache stringify_keys Result

**Problem:** `stringify_keys` is called on every scope push/init, allocating new hashes.

**Memory evidence:** Hash allocations are 14,000 objects (31%) of render-time allocations.

**Proposed improvement:** Accept pre-stringified hashes or cache the result:
```ruby
def push_scope(scope = {})
  # Skip stringification if scope is already string-keyed (common case)
  @scopes.unshift(scope.keys.first.is_a?(String) || scope.empty? ? scope : stringify_keys(scope))
end
```

---

### Priority 3: Compiler Optimizations (Medium Impact)

#### 3.1 Cache find_max_temp_index Result

**Problem:** `find_max_temp_index` iterates all instructions and is called multiple times.

**Profile evidence:** 6.3% of compile time.

**Proposed improvement:** Compute once and cache, or track incrementally during IL generation:
```ruby
# Track during IL building
@max_temp_index = -1
def emit_store_temp(idx)
  @max_temp_index = [max_temp_index, idx].max
  emit(IL::STORE_TEMP, idx)
end
```

---

#### 3.2 Optimize control_flow_boundary? Dispatch

**Problem:** `control_flow_boundary?` uses `case/when` for 14 opcodes, called per-instruction.

**Profile evidence:** 3.8% of compile time.

**Proposed improvement:** Use a frozen set for O(1) lookup:
```ruby
CONTROL_FLOW_OPCODES = [
  IL::LABEL, IL::JUMP, IL::JUMP_IF_TRUE, # ...
].to_set.freeze

def control_flow_boundary?(inst)
  CONTROL_FLOW_OPCODES.include?(inst[0])
end
```

---

#### 3.3 Reduce String Allocations in Code Generation

**Problem:** Code generation uses string interpolation heavily, allocating many intermediate strings.

**Memory evidence:** String allocations are 2.84MB (48%) of compile-time memory.

**Proposed improvement:** Use heredocs and pre-allocated string buffers:
```ruby
# Before
code << "  __stack__ << #{inst[1]}\n"

# After - use heredoc templates
CONST_INT_TEMPLATE = "  __stack__ << %s\n"
code << (CONST_INT_TEMPLATE % inst[1])
```

---

#### 3.4 Avoid gsub in instruction generation

**Problem:** `generate_instruction_for_state_machine` calls `gsub(/^  /, "      ")` to reindent code.

**Profile evidence:** `String#gsub` is 2.8% of compile time.

**Proposed improvement:** Generate with correct indentation from the start:
```ruby
def generate_instruction(inst, idx, indent: "  ")
  case opcode
  when IL::WRITE_RAW
    "#{indent}__output__ << #{inst[1].inspect}\n"
  # ...
  end
end
```

---

### Priority 4: Filter and Utility Optimizations (Lower Impact)

#### 4.1 Inline Common Filters

**Problem:** Filter dispatch goes through `Filters.apply` which uses `respond_to?` and `method`.

**Profile evidence:** `Filters.apply` is 2.5% of render time, `Method#===` checks visible.

**Proposed improvement:** Inline common zero-arg filters in generated code:
```ruby
# Before
__call_filter__("escape", value, [], ...)

# After - for common filters
CGI.escapeHTML(value.to_s)
```

Filters to inline: `escape`, `upcase`, `downcase`, `size`, `first`, `last`, `strip`.

---

#### 4.2 Specialize Utils.output_string

**Problem:** `output_string` has a case statement checked on every call.

**Proposed improvement:** Use method dispatch instead:
```ruby
module OutputString
  refine String do
    def to_output = self
  end
  refine Integer do
    def to_output = to_s
  end
  # ...
end

# In generated code
__output__ << value.to_output
```

---

### Priority 5: Structural Improvements (Larger Effort)

#### 5.1 Pre-compile to Ruby Files

**Problem:** `Kernel#eval` is 13.4% of compile time.

**Proposed improvement:** Support pre-compilation to `.rb` files that can be `require`d:
```bash
liquid-il compile templates/*.liquid --output compiled/
```

Benefits:
- One-time compilation cost
- Ruby VM can optimize the code better
- Enables YJIT/JIT optimization

---

#### 5.2 Native Extension for Hot Paths

**Problem:** Certain operations like lookup_property and is_truthy are called millions of times.

**Proposed improvement:** Move hot paths to C extension:
```c
// ext/liquid_il/lookup.c
VALUE liquid_il_lookup_property(VALUE obj, VALUE key) {
  if (RB_TYPE_P(obj, T_HASH)) {
    VALUE result = rb_hash_aref(obj, key);
    if (!NIL_P(result)) return result;
    // ...
  }
  // ...
}
```

---

#### 5.3 Template Specialization

**Problem:** Generic code handles all template patterns.

**Proposed improvement:** Generate specialized code for common patterns:
- **Output-only templates:** Skip scope, stack, iterators setup
- **Loop-free templates:** Skip iterator handling
- **Capture-free templates:** Use direct string append

---

## Implementation Roadmap

### Phase 1: Quick Wins (1-2 days each)
1. [ ] Skip state machine for linear templates (1.1)
2. [ ] Cache find_max_temp_index (3.1)
3. [ ] Use Set for control_flow_boundary? (3.2)
4. [ ] Skip ErrorMarker check for safe ops (1.4)

### Phase 2: Generated Code Quality (3-5 days each)
1. [ ] Consistent variable hoisting (1.2)
2. [ ] Specialized output for known types (1.3)
3. [ ] Inline common filters (4.1)

### Phase 3: Runtime Optimizations (3-5 days each)
1. [ ] Fast path scope lookup (2.1)
2. [ ] Lazy scope initialization (2.2)
3. [ ] Skip stringify_keys when possible (2.3)

### Phase 4: Structural (1-2 weeks each)
1. [ ] Pre-compilation to Ruby files (5.1)
2. [ ] Template specialization (5.3)
3. [ ] Native extension evaluation (5.2)

---

## Success Metrics

| Metric | Current | Target | Method |
|--------|---------|--------|--------|
| Compile time (complex) | 0.65ms | 0.35ms | Phase 1-2 |
| Render time (complex) | 0.021ms | 0.012ms | Phase 2-3 |
| Compile allocations | 657 | 350 | Phase 1-2 |
| Render allocations | 61 | 30 | Phase 2-3 |

---

## Appendix: Generated Code Example

### Current Generated Code (complex_ecommerce)
```ruby
# frozen_string_literal: true
proc do |__scope__, __spans__, __template_source__|
  __output__ = String.new(capacity: 8192)
  __stack__ = []
  __for_iterators__ = []
  __current_file__ = nil

  __pc__ = 0
  while true
    case __pc__
    when 0
      __output__ << "<div class=\"product\">\n  <h1>"
      __t0__ = __scope__.lookup("product");
      __output__ << (__v__ = __call_filter__("escape", __lookup_property__(__t0__, "title"), [], __scope__, __spans__, __template_source__, 5, __current_file__); __v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : LiquidIL::Utils.output_string(__v__))
      # ... 16 more states ...
    end
  end
  __output__
end
```

### Ideal Generated Code
```ruby
# frozen_string_literal: true
proc do |assigns|
  product = assigns["product"]
  output = String.new(capacity: 8192)

  output << "<div class=\"product\">\n  <h1>"
  output << CGI.escapeHTML(product["title"].to_s)
  output << "</h1>\n  <p class=\"price\">"
  output << product["price"].to_s
  output << "</p>\n  "

  if product["on_sale"]
    output << "\n    <span class=\"sale-badge\">SALE!</span>\n  "
  end

  output << "\n  <ul class=\"variants\">\n  "

  product["variants"]&.each do |variant|
    output << "\n    <li>\n      "
    output << variant["title"].to_s
    output << " - "
    output << variant["price"].to_s
    # ...
  end

  output
end
```

---

## References

- Profile dumps: `tmp/compile_profile.dump`, `tmp/render_profile.dump`
- Memory reports: `tmp/compile_memory.txt`, `tmp/render_memory.txt`
- Profiling script: `profile_comprehensive.rb`
