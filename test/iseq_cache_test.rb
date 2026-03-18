# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# ════════════════════════════════════════════════════════════
# HELPERS
# ════════════════════════════════════════════════════════════

class SimpleFS
  def initialize(files)
    @files = {}
    files.each { |k, v| @files[k] = v }
  end

  def read_template_file(name)
    @files[name]
  end
end

# ════════════════════════════════════════════════════════════
# Template#iseq_binary
# ════════════════════════════════════════════════════════════

class IseqBinaryTest < Minitest::Test
  def test_iseq_binary_returns_a_string
    t = LiquidIL.parse("Hello {{ name }}")
    bin = t.iseq_binary
    assert_kind_of String, bin
    refute_empty bin
  end

  def test_iseq_binary_is_frozen
    t = LiquidIL.parse("Hello {{ name }}")
    assert_predicate t.iseq_binary, :frozen?
  end

  def test_iseq_binary_is_stable
    t = LiquidIL.parse("Hello {{ name }}")
    assert_equal t.iseq_binary, t.iseq_binary, "calling iseq_binary twice should return the same object"
    assert_same t.iseq_binary, t.iseq_binary, "should be the exact same frozen object"
  end

  def test_iseq_binary_is_loadable
    t = LiquidIL.parse("Hello {{ name }}")
    iseq = RubyVM::InstructionSequence.load_from_binary(t.iseq_binary)
    result = iseq.eval
    assert_kind_of Proc, result
  end
end

# ════════════════════════════════════════════════════════════
# Template#cache_data
# ════════════════════════════════════════════════════════════

class CacheDataTest < Minitest::Test
  def test_cache_data_keys
    t = LiquidIL.parse("Hello")
    data = t.cache_data
    assert_kind_of Hash, data
    assert_includes data.keys, :source
    assert_includes data.keys, :spans
    assert_includes data.keys, :iseq_binary
    assert_includes data.keys, :partial_constants
  end

  def test_cache_data_source_matches
    src = "Hello {{ name }}"
    t = LiquidIL.parse(src)
    assert_equal src, t.cache_data[:source]
  end

  def test_cache_data_spans_is_array
    t = LiquidIL.parse("Hello {{ name }}")
    assert_kind_of Array, t.cache_data[:spans]
  end

  def test_cache_data_iseq_binary_matches
    t = LiquidIL.parse("Hello {{ name }}")
    assert_equal t.iseq_binary, t.cache_data[:iseq_binary]
  end
end

# ════════════════════════════════════════════════════════════
# Roundtrip: cache_data → from_cache
# ════════════════════════════════════════════════════════════

class IseqRoundtripTest < Minitest::Test
  def test_simple_text
    assert_roundtrip "Hello World", {}
  end

  def test_variable_interpolation
    assert_roundtrip "Hello {{ name }}", { "name" => "World" }
  end

  def test_multiple_variables
    assert_roundtrip "{{ a }} and {{ b }}", { "a" => "X", "b" => "Y" }
  end

  def test_filter_chain
    assert_roundtrip "{{ name | upcase | truncate: 5 }}", { "name" => "hello world" }
  end

  def test_if_else
    src = "{% if show %}yes{% else %}no{% endif %}"
    assert_roundtrip src, { "show" => true }
    assert_roundtrip src, { "show" => false }
  end

  def test_for_loop
    assert_roundtrip(
      "{% for i in items %}{{ i }} {% endfor %}",
      { "items" => [1, 2, 3] }
    )
  end

  def test_for_loop_with_forloop_variable
    assert_roundtrip(
      "{% for i in items %}{{ forloop.index }}{% endfor %}",
      { "items" => %w[a b c] }
    )
  end

  def test_assign
    assert_roundtrip(
      "{% assign x = 'hello' | upcase %}{{ x }}",
      {}
    )
  end

  def test_capture
    assert_roundtrip(
      "{% capture greeting %}Hello {{ name }}{% endcapture %}{{ greeting }}!",
      { "name" => "World" }
    )
  end

  def test_unless
    assert_roundtrip(
      "{% unless hidden %}visible{% endunless %}",
      { "hidden" => false }
    )
  end

  def test_case_when
    src = "{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}"
    assert_roundtrip src, { "x" => 1 }
    assert_roundtrip src, { "x" => 2 }
    assert_roundtrip src, { "x" => 99 }
  end

  def test_nested_objects
    assert_roundtrip(
      "{{ user.name }} is {{ user.age }}",
      { "user" => { "name" => "Alice", "age" => 30 } }
    )
  end

  def test_array_indexing
    assert_roundtrip(
      "{{ items[0] }} and {{ items[1] }}",
      { "items" => %w[first second] }
    )
  end

  def test_whitespace_control
    assert_roundtrip(
      "{%- if true -%}  hello  {%- endif -%}",
      {}
    )
  end

  def test_increment_decrement
    assert_roundtrip "{% increment x %}{% increment x %}{% decrement y %}{% decrement y %}", {}
  end

  def test_cycle
    assert_roundtrip(
      "{% for i in items %}{% cycle 'a', 'b', 'c' %}{% endfor %}",
      { "items" => [1, 2, 3, 4, 5] }
    )
  end

  def test_raw
    assert_roundtrip "{% raw %}{{ not_a_variable }}{% endraw %}", {}
  end

  def test_comment
    assert_roundtrip "before{% comment %}hidden{% endcomment %}after", {}
  end

  def test_empty_template
    assert_roundtrip "", {}
  end

  def test_math_filters
    assert_roundtrip "{{ 10 | plus: 5 | minus: 3 | times: 2 }}", {}
  end

  def test_string_filters
    assert_roundtrip '{{ "hello world" | split: " " | first | capitalize }}', {}
  end

  def test_range_for_loop
    assert_roundtrip "{% for i in (1..5) %}{{ i }}{% endfor %}", {}
  end

  def test_contains_operator
    assert_roundtrip(
      '{% if items contains "b" %}yes{% else %}no{% endif %}',
      { "items" => %w[a b c] }
    )
  end

  def test_multiple_renders_from_cached_template
    t = LiquidIL.parse("Hello {{ name }}")
    restored = LiquidIL::Template.from_cache(**t.cache_data)

    assert_equal "Hello Alice", restored.render("name" => "Alice")
    assert_equal "Hello Bob", restored.render("name" => "Bob")
    assert_equal "Hello ", restored.render({})
  end

  def test_restored_iseq_binary_matches_original
    t = LiquidIL.parse("Hello {{ name }}")
    data = t.cache_data

    restored = LiquidIL::Template.from_cache(**data)
    assert_equal data[:iseq_binary], restored.iseq_binary
  end

  def test_double_roundtrip
    t1 = LiquidIL.parse("{{ x | plus: 1 }}")
    t2 = LiquidIL::Template.from_cache(**t1.cache_data)
    t3 = LiquidIL::Template.from_cache(**t2.cache_data)

    assert_equal "6", t1.render("x" => 5)
    assert_equal "6", t2.render("x" => 5)
    assert_equal "6", t3.render("x" => 5)
  end

  private

  def assert_roundtrip(source, assigns)
    original = LiquidIL.parse(source)
    expected = original.render(assigns)

    restored = LiquidIL::Template.from_cache(**original.cache_data)
    actual = restored.render(assigns)

    assert_equal expected, actual,
      "Roundtrip mismatch for #{source.inspect} with #{assigns.inspect}"
  end
end

# ════════════════════════════════════════════════════════════
# Roundtrip with partials (require file_system via Context)
# ════════════════════════════════════════════════════════════

class IseqRoundtripWithPartialsTest < Minitest::Test
  def test_render_partial
    fs = SimpleFS.new("greeting" => "Hi {{ name }}!")
    ctx = LiquidIL::Context.new(file_system: fs)
    t = ctx.parse("{% render 'greeting', name: 'World' %}")

    expected = t.render
    data = t.cache_data

    refute_nil data[:partial_constants], "template with partials should have partial_constants"

    restored = LiquidIL::Template.from_cache(**data)
    assert_equal expected, restored.render
  end

  def test_include_partial
    fs = SimpleFS.new("item" => "{{ title }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    t = ctx.parse("{% include 'item' %}")

    expected = t.render("title" => "Hello")
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal expected, restored.render("title" => "Hello")
  end

  def test_nested_partials
    fs = SimpleFS.new(
      "outer" => "OUTER:{% render 'inner', val: val %}",
      "inner" => "INNER:{{ val }}"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    t = ctx.parse("{% render 'outer', val: 'X' %}")

    expected = t.render
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal expected, restored.render
  end
end

# ════════════════════════════════════════════════════════════
# StructuredCompiler.iseq_binary_for
# ════════════════════════════════════════════════════════════

class IseqBinaryForTest < Minitest::Test
  def test_returns_binary_string
    source = "proc { |x| x + 1 }"
    bin = LiquidIL::StructuredCompiler.iseq_binary_for(source)
    assert_kind_of String, bin
    refute_empty bin
  end

  def test_binary_is_frozen
    source = "proc { |x| x * 2 }"
    bin = LiquidIL::StructuredCompiler.iseq_binary_for(source)
    assert_predicate bin, :frozen?
  end

  def test_binary_is_loadable
    source = "proc { |x| x + 10 }"
    bin = LiquidIL::StructuredCompiler.iseq_binary_for(source)
    result = RubyVM::InstructionSequence.load_from_binary(bin).eval
    assert_equal 15, result.call(5)
  end

  def test_same_source_returns_same_binary
    source = "proc { :test_stable }"
    bin1 = LiquidIL::StructuredCompiler.iseq_binary_for(source)
    bin2 = LiquidIL::StructuredCompiler.iseq_binary_for(source)
    assert_equal bin1, bin2
  end
end

# ════════════════════════════════════════════════════════════
# Edge cases and error handling
# ════════════════════════════════════════════════════════════

class IseqCacheEdgeCasesTest < Minitest::Test
  def test_from_cache_with_nil_partial_constants
    t = LiquidIL.parse("just text")
    data = t.cache_data
    assert_nil data[:partial_constants], "simple template should have nil partial_constants"

    restored = LiquidIL::Template.from_cache(**data)
    assert_equal "just text", restored.render
  end

  def test_from_cache_preserves_source
    src = "Hello {{ name }}"
    t = LiquidIL.parse(src)
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal src, restored.source
  end

  def test_cached_template_handles_missing_variables
    t = LiquidIL.parse("Hello {{ name }}")
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal "Hello ", restored.render({})
  end

  def test_cached_template_handles_nil_values
    t = LiquidIL.parse("Hello {{ name }}")
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal "Hello ", restored.render("name" => nil)
  end

  def test_cached_template_with_complex_assigns
    t = LiquidIL.parse("{{ items | size }} items")
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal "3 items", restored.render("items" => [1, 2, 3])
  end
end
