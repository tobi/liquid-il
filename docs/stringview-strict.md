# StringView::Strict Usage Guide

## What is StringView::Strict?

`StringView::Strict` is a C-level subclass of `StringView` that **raises instead of allocating**. Same struct, same memory layout — the class pointer is the only difference.

Use it in the parse pipeline to guarantee zero String allocations. Any accidental `.to_s`, `.upcase`, `.split`, etc. will blow up immediately instead of silently creating garbage.

## Creating

```ruby
view = StringView::Strict.new(source, offset, length)
```

Slicing preserves the class — a slice of Strict returns Strict:
```ruby
view.strip.delete_prefix("foo").chr  # => StringView::Strict
view[0, 5]                            # => StringView::Strict
view.byteslice(3, 4)                  # => StringView::Strict
```

## What Works (zero alloc)

### Primitives — return integers, booleans, nil
```ruby
view.bytesize          # => Integer
view.length / view.size # => Integer
view.empty?            # => true/false
view.getbyte(i)        # => Integer or nil
view.ord               # => Integer
view.to_i / view.to_f  # => Numeric
view.hash              # => Integer
view.encoding          # => Encoding
view.ascii_only?       # => true/false
view.valid_encoding?   # => true/false
```

### Comparisons — return booleans
```ruby
view == "string"         # => true/false (works with String and StringView)
view.eql?("string")     # => true/false
view <=> other           # => -1/0/1
view.include?("sub")    # => true/false
view.start_with?("pre") # => true/false
view.end_with?("suf")   # => true/false
```

### Search — return integers
```ruby
view.index("sub")       # => Integer or nil
view.rindex("sub")      # => Integer or nil
view.byteindex("sub")   # => Integer or nil
view.byterindex("sub")  # => Integer or nil
```

### Zero-copy transforms — return StringView::Strict
These adjust offset/length without touching bytes:
```ruby
view.strip / view.lstrip / view.rstrip  # trim whitespace
view.chomp / view.chomp(sep)            # remove trailing separator
view.chop                               # remove last char
view.delete_prefix("pre")              # advance past prefix
view.delete_suffix("suf")              # shrink past suffix
view.chr                                # first character
view[start, len]                        # substring
view.byteslice(start, len)             # byte substring
```

### Iteration
```ruby
view.each_byte { |b| ... }  # yields integers
view.bytes                   # Array of integers
```

## What Raises (would allocate)

All of these raise `StringView::WouldAllocate`:

```ruby
view.to_s          # ❌ — use .materialize instead
view.to_str        # ❌ — implicit coercion blocked
view.upcase        # ❌
view.downcase      # ❌
view.gsub(...)     # ❌
view.sub(...)      # ❌
view.split(...)    # ❌
view.reverse       # ❌
view.encode(...)   # ❌
view.freeze        # ❌ (would create a String)
view.match(...)    # ❌
view.match?(...)   # ❌
view =~ /re/       # ❌
view.index(/re/)   # ❌ (regex form — string form works)
view.inspect       # ✅ (exception: always works for debugging)
view + other       # ❌ (concatenation allocates)
```

## Escape Hatches

### `.materialize` — explicit allocation
When you truly need a String (e.g., passing to the IL instruction stream for structured compilation):
```ruby
str = view.materialize  # => frozen String
```

### `.reset!(backing, offset, length)` — repoint the view
Zero-alloc way to make an existing view point at different bytes:
```ruby
view.reset!(new_source, new_offset, new_length)
```

## In LiquidIL

**Parse phase** (lexer.rb, parser.rb): Create `StringView::Strict` for RAW content. The strict mode acts as a compile-time assertion that no String allocations leak through.

**Compiler passes** (compiler.rb): When merging WRITE_RAW instructions, call `.materialize` to get Strings before concatenation.

**Structured compiler** (structured_compiler.rb): Call `.materialize` instead of `.to_s` to get the String for `.inspect` in code generation.

**Key rule**: If your code runs during parsing and touches a StringView, use Strict. If your code runs during compilation and needs a real String, call `.materialize`.
