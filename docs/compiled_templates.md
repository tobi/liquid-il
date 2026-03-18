# Saving and Loading Compiled Templates

LiquidIL supports two persistence modes for compiled templates:

1. **Ruby source modules** (`to_ruby` / `write_ruby`)
2. **RubyVM ISeq binaries** (`write_iseq` / `load_iseq`, and `write_cache` / `load_cache`)

---

## Ruby Source Export

```ruby
template = LiquidIL.parse("Hello {{ name | upcase }}")
template.write_ruby("greeting.rb", module_name: "Greeting")

require_relative "greeting"
Greeting.render("name" => "world")
# => "Hello WORLD"
```

Use this when you want human-readable output and normal source control diffability.

---

## Raw ISeq Binary Export

```ruby
template = LiquidIL.parse("Hello {{ name }}")
template.write_iseq("greeting.iseq")

restored = LiquidIL::Template.load_iseq(
  "greeting.iseq",
  source: "Hello {{ name }}", # optional but recommended
  spans: template.spans         # optional but recommended
)

restored.render("name" => "World")
# => "Hello World"
```

Use this when you want the smallest/faster loadable artifact.

---

## Full Cache Payload (recommended for app caches)

```ruby
template = LiquidIL.parse("Hello {{ name }}")
template.write_cache("greeting.ilc")

restored = LiquidIL::Template.load_cache("greeting.ilc")
restored.render("name" => "World")
# => "Hello World"
```

`write_cache` persists:
- `source`
- `spans`
- `iseq_binary`
- `partial_constants`

So this roundtrip preserves rich runtime behavior/error metadata.

---

## Low-level direct `.call`

You can bypass `LiquidIL::Template` and call the proc directly:

```ruby
bin = File.binread("greeting.iseq")
proc_obj = RubyVM::InstructionSequence.load_from_binary(bin).eval

scope = LiquidIL::Scope.new("name" => "World")
out = proc_obj.call(scope, [[0, 15]], "Hello {{ name }}")
```

For most cases, prefer `Template.load_iseq`/`Template.load_cache`.

---

## Important caveats

- ISeq binaries are **Ruby-version specific**.
- They may also be sensitive to VM/build/platform differences.
- If your deployment Ruby changes, regenerate binaries.
- For long-lived caches shared across environments, store source as fallback.
