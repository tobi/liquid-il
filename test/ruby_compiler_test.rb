# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class RubyCompilerTest < Minitest::Test
  def compile(source, **assigns)
    LiquidIL::Compiler::Ruby.compile(source).render(assigns)
  end

  def test_simple_output
    assert_equal "Hello World", compile("Hello World")
  end

  def test_variable_interpolation
    assert_equal "Hello Alice", compile("Hello {{ name }}", name: "Alice")
  end

  def test_multiple_variables
    assert_equal "Bob is 25", compile("{{ name }} is {{ age }}", name: "Bob", age: 25)
  end

  def test_nested_property
    assert_equal "Tokyo", compile("{{ user.city }}", user: { "city" => "Tokyo" })
  end

  def test_array_access
    assert_equal "b", compile("{{ items[1] }}", items: %w[a b c])
  end

  def test_if_true
    assert_equal "yes", compile("{% if show %}yes{% endif %}", show: true)
  end

  def test_if_false
    assert_equal "", compile("{% if show %}yes{% endif %}", show: false)
  end

  def test_if_else_true
    assert_equal "yes", compile("{% if x %}yes{% else %}no{% endif %}", x: true)
  end

  def test_if_else_false
    assert_equal "no", compile("{% if x %}yes{% else %}no{% endif %}", x: false)
  end

  def test_unless_true
    assert_equal "", compile("{% unless hide %}visible{% endunless %}", hide: true)
  end

  def test_unless_false
    assert_equal "visible", compile("{% unless hide %}visible{% endunless %}", hide: false)
  end

  def test_for_loop
    assert_equal "123", compile("{% for i in items %}{{ i }}{% endfor %}", items: [1, 2, 3])
  end

  def test_for_loop_with_separator
    assert_equal "1, 2, 3", compile("{% for i in items %}{{ i }}{% unless forloop.last %}, {% endunless %}{% endfor %}", items: [1, 2, 3])
  end

  def test_for_loop_empty
    assert_equal "", compile("{% for i in items %}{{ i }}{% endfor %}", items: [])
  end

  def test_for_else
    assert_equal "empty", compile("{% for i in items %}{{ i }}{% else %}empty{% endfor %}", items: [])
  end

  def test_forloop_index
    assert_equal "1-2-3", compile("{% for i in items %}{{ forloop.index }}{% unless forloop.last %}-{% endunless %}{% endfor %}", items: %w[a b c])
  end

  def test_forloop_first_last
    assert_equal "[a-b-c]", compile("{% for i in items %}{% if forloop.first %}[{% endif %}{{ i }}{% if forloop.last %}]{% endif %}{% unless forloop.last %}-{% endunless %}{% endfor %}", items: %w[a b c])
  end

  def test_assign
    assert_equal "hello", compile("{% assign x = 'hello' %}{{ x }}")
  end

  def test_capture
    assert_equal "captured!", compile("{% capture msg %}captured!{% endcapture %}{{ msg }}")
  end

  def test_increment
    assert_equal "0-1-2", compile("{% increment x %}-{% increment x %}-{% increment x %}")
  end

  def test_decrement
    assert_equal "-1--2--3", compile("{% decrement x %}-{% decrement x %}-{% decrement x %}")
  end

  def test_cycle
    assert_equal "a-b-c-a-b", compile("{% for i in (1..5) %}{% cycle 'a', 'b', 'c' %}{% unless forloop.last %}-{% endunless %}{% endfor %}")
  end

  def test_filter_upcase
    assert_equal "HELLO", compile("{{ 'hello' | upcase }}")
  end

  def test_filter_downcase
    assert_equal "hello", compile("{{ 'HELLO' | downcase }}")
  end

  def test_filter_size
    assert_equal "3", compile("{{ items | size }}", items: [1, 2, 3])
  end

  def test_filter_chained
    assert_equal "HELLO WORLD", compile("{{ msg | upcase | strip }}", msg: "  hello world  ")
  end

  def test_comparison_eq
    assert_equal "yes", compile("{% if x == 1 %}yes{% endif %}", x: 1)
    assert_equal "", compile("{% if x == 1 %}yes{% endif %}", x: 2)
  end

  def test_comparison_ne
    assert_equal "yes", compile("{% if x != 1 %}yes{% endif %}", x: 2)
    assert_equal "", compile("{% if x != 1 %}yes{% endif %}", x: 1)
  end

  def test_comparison_lt
    assert_equal "yes", compile("{% if x < 10 %}yes{% endif %}", x: 5)
    assert_equal "", compile("{% if x < 10 %}yes{% endif %}", x: 15)
  end

  def test_contains_string
    assert_equal "yes", compile("{% if msg contains 'world' %}yes{% endif %}", msg: "hello world")
    assert_equal "", compile("{% if msg contains 'foo' %}yes{% endif %}", msg: "hello world")
  end

  def test_contains_array
    assert_equal "yes", compile("{% if items contains 'b' %}yes{% endif %}", items: %w[a b c])
    assert_equal "", compile("{% if items contains 'x' %}yes{% endif %}", items: %w[a b c])
  end

  def test_and_operator
    assert_equal "yes", compile("{% if a and b %}yes{% endif %}", a: true, b: true)
    assert_equal "", compile("{% if a and b %}yes{% endif %}", a: true, b: false)
  end

  def test_or_operator
    assert_equal "yes", compile("{% if a or b %}yes{% endif %}", a: false, b: true)
    assert_equal "", compile("{% if a or b %}yes{% endif %}", a: false, b: false)
  end

  def test_range_literal
    assert_equal "12345", compile("{% for i in (1..5) %}{{ i }}{% endfor %}")
  end

  def test_case_when
    result = compile("{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", x: 1)
    assert_equal "one", result

    result = compile("{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", x: 2)
    assert_equal "two", result

    result = compile("{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", x: 3)
    assert_equal "other", result
  end

  def test_blank_comparison
    assert_equal "yes", compile("{% if '' == blank %}yes{% endif %}")
    assert_equal "yes", compile("{% if '  ' == blank %}yes{% endif %}")
    assert_equal "", compile("{% if 'x' == blank %}yes{% endif %}")
  end

  def test_empty_comparison
    assert_equal "yes", compile("{% if '' == empty %}yes{% endif %}")
    assert_equal "yes", compile("{% if arr == empty %}yes{% endif %}", arr: [])
    assert_equal "", compile("{% if 'x' == empty %}yes{% endif %}")
  end

  def test_nil_output
    assert_equal "", compile("{{ x }}", x: nil)
  end

  def test_compiled_uses_ruby_not_vm
    template = LiquidIL::Compiler::Ruby.compile("Hello {{ name }}")
    refute template.uses_vm, "Simple template should use compiled Ruby"
    assert template.compiled_source, "Should have generated source"
  end

  def test_vm_fallback_for_render
    template = LiquidIL::Compiler::Ruby.compile("{% render 'partial' %}")
    assert template.uses_vm, "Render tag should fall back to VM"
  end

  def test_vm_fallback_for_include
    template = LiquidIL::Compiler::Ruby.compile("{% include 'partial' %}")
    assert template.uses_vm, "Include tag should fall back to VM"
  end

  def test_generated_code_quality
    template = LiquidIL::Compiler::Ruby.compile("Hello {{ name }}!")
    source = template.compiled_source

    # Should be compact, no unnecessary state machine for linear code
    refute_match /__pc__/, source, "Simple linear code shouldn't need state machine"
    assert_match /\A# frozen_string_literal: true/, source, "Should have frozen string literal"
    assert_match /__output__ = String\.new/, source, "Should use String.new for output"
  end

  def test_for_with_limit
    assert_equal "12", compile("{% for i in items limit:2 %}{{ i }}{% endfor %}", items: [1, 2, 3, 4, 5])
  end

  def test_for_with_offset
    assert_equal "345", compile("{% for i in items offset:2 %}{{ i }}{% endfor %}", items: [1, 2, 3, 4, 5])
  end

  def test_break
    assert_equal "12", compile("{% for i in items %}{{ i }}{% if i == 2 %}{% break %}{% endif %}{% endfor %}", items: [1, 2, 3, 4])
  end

  def test_continue
    assert_equal "134", compile("{% for i in items %}{% if i == 2 %}{% continue %}{% endif %}{{ i }}{% endfor %}", items: [1, 2, 3, 4])
  end

  def test_nested_loops
    result = compile("{% for i in outer %}{% for j in inner %}{{ i }}{{ j }} {% endfor %}{% endfor %}", outer: [1, 2], inner: %w[a b])
    assert_equal "1a 1b 2a 2b ", result
  end

  def test_comment_ignored
    assert_equal "hello", compile("hello{% comment %}ignored{% endcomment %}")
  end

  def test_raw_passthrough
    assert_equal "{{ not parsed }}", compile("{% raw %}{{ not parsed }}{% endraw %}")
  end

  def test_whitespace_trimming
    assert_equal "ab", compile("a {%- if true -%} b {%- endif -%}")
  end

  def test_echo
    assert_equal "hello", compile("{% echo 'hello' %}")
    assert_equal "HELLO", compile("{% echo 'hello' | upcase %}")
  end

  def test_tablerow
    result = compile("{% tablerow i in items cols:2 %}{{ i }}{% endtablerow %}", items: %w[a b c])
    assert_match %r{<tr class="row1">}, result
    assert_match %r{<td class="col1">a</td>}, result
    assert_match %r{<td class="col2">b</td>}, result
  end

  def test_tablerow_compiled_not_vm
    template = LiquidIL::Compiler::Ruby.compile("{% tablerow i in items %}{{ i }}{% endtablerow %}")
    refute template.uses_vm, "Tablerow should use compiled Ruby, not VM"
  end

  def test_save_creates_standalone_file
    require "tempfile"

    template = LiquidIL::Compiler::Ruby.compile("Hello {{ name | upcase }}!")

    Tempfile.create(["compiled", ".rb"]) do |f|
      template.save(f.path)
      content = File.read(f.path)

      # Check structure
      assert_match %r{require "liquid_il"}, content
      assert_match %r{module CompiledLiquidTemplate}, content
      assert_match %r{def render\(assigns = \{\}\)}, content
      assert_match %r{# Original template:}, content

      # Load and execute the saved file
      load f.path
      result = CompiledLiquidTemplate.render("name" => "world")
      assert_equal "Hello WORLD!", result
    end
  end

  def test_save_raises_for_vm_fallback
    # render/include tags require VM fallback
    template = LiquidIL::Compiler::Ruby.compile("{% render 'partial' %}")
    assert template.uses_vm

    assert_raises(RuntimeError) do
      template.save("/tmp/test.rb")
    end
  end
end
