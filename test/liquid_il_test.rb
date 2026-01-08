# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class ContextTest < Minitest::Test
  def test_basic_render
    ctx = LiquidIL::Context.new
    assert_equal "Hello World", ctx.render("Hello {{ name }}", name: "World")
  end

  def test_render_with_hash_assigns
    ctx = LiquidIL::Context.new
    assert_equal "Hello Ruby", ctx.render("Hello {{ name }}", { "name" => "Ruby" })
  end

  def test_parse_returns_template
    ctx = LiquidIL::Context.new
    template = ctx.parse("Hello {{ name }}")
    assert_instance_of LiquidIL::Template, template
  end

  def test_template_render
    ctx = LiquidIL::Context.new
    template = ctx.parse("{{ x }} + {{ y }}")
    assert_equal "1 + 2", template.render(x: 1, y: 2)
    assert_equal "10 + 20", template.render(x: 10, y: 20)
  end

  def test_hash_access_caches_templates
    ctx = LiquidIL::Context.new
    t1 = ctx["Hello {{ name }}"]
    t2 = ctx["Hello {{ name }}"]
    assert_same t1, t2
  end

  def test_clear_cache
    ctx = LiquidIL::Context.new
    t1 = ctx["Hello"]
    ctx.clear_cache
    t2 = ctx["Hello"]
    refute_same t1, t2
  end

  def test_file_system
    fs = { "header" => "HEADER" }
    ctx = LiquidIL::Context.new(file_system: FileSystem.new(fs))
    assert_equal "HEADER", ctx.render("{% include 'header' %}")
  end

  def test_strict_errors_propagates
    ctx = LiquidIL::Context.new(strict_errors: true)
    assert ctx.strict_errors
  end
end

class TemplateTest < Minitest::Test
  def test_standalone_parse
    template = LiquidIL::Template.parse("Hello {{ name }}")
    assert_equal "Hello World", template.render(name: "World")
  end

  def test_source_preserved
    template = LiquidIL::Template.parse("Hello {{ name }}")
    assert_equal "Hello {{ name }}", template.source
  end

  def test_instructions_present
    template = LiquidIL::Template.parse("Hello")
    assert_kind_of Array, template.instructions
    refute_empty template.instructions
  end
end

class ModuleLevelAPITest < Minitest::Test
  def test_parse
    template = LiquidIL.parse("Hello {{ name }}")
    assert_instance_of LiquidIL::Template, template
  end

  def test_render
    assert_equal "Hello World", LiquidIL.render("Hello {{ name }}", name: "World")
  end

  def test_render_with_hash
    assert_equal "Hello Ruby", LiquidIL.render("Hello {{ name }}", { "name" => "Ruby" })
  end
end

class OptimizerTest < Minitest::Test
  def test_optimizer_wraps_context
    ctx = LiquidIL::Context.new
    opt = LiquidIL::Optimizer.optimize(ctx)
    assert_instance_of LiquidIL::OptimizedContext, opt
  end

  def test_optimizer_is_idempotent
    ctx = LiquidIL::Context.new
    opt1 = LiquidIL::Optimizer.optimize(ctx)
    opt2 = LiquidIL::Optimizer.optimize(opt1)
    assert_same opt1, opt2
  end

  def test_optimizer_preserves_context_options
    ctx = LiquidIL::Context.new(strict_errors: true, registers: { "x" => 1 })
    opt = LiquidIL::Optimizer.optimize(ctx)
    assert opt.strict_errors
    assert_equal({ "x" => 1 }, opt.registers)
  end

  def test_optimizer_enables_compile_optimizations
    ctx = LiquidIL::Context.new
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{{ true }}")
    instructions = template.instructions.map(&:first)
    refute_includes instructions, LiquidIL::IL::WRITE_VALUE
    assert_includes instructions, LiquidIL::IL::WRITE_RAW
  end
end

class ILOptimizationTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_const_write_value_folded
    template = @ctx.parse("{{ 'hello' }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::WRITE_VALUE
    assert_includes opcodes, LiquidIL::IL::WRITE_RAW
  end

  def test_const_if_branch_eliminated
    template = @ctx.parse("{% if false %}no{% else %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_FALSE
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_TRUE
    assert_includes opcodes, LiquidIL::IL::JUMP
  end

  def test_jump_to_next_label_removed
    template = @ctx.parse("{% if false %}a{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_FALSE
  end

  def test_noop_removed
    template = @ctx.parse("{% comment %}ignored{% endcomment %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::NOOP
  end

  def test_lookup_const_path_collapsed
    template = @ctx.parse("{{ user.name.first }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    assert_includes opcodes, LiquidIL::IL::FIND_VAR_PATH
    refute_includes opcodes, LiquidIL::IL::LOOKUP_CONST_KEY
    refute_includes opcodes, LiquidIL::IL::LOOKUP_CONST_PATH
  end

  def test_const_filter_folded
    template = @ctx.parse("{{ 'hello' | upcase }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::CALL_FILTER
    assert_includes opcodes, LiquidIL::IL::WRITE_RAW
  end

  def test_redundant_is_truthy_removed_for_compare
    template = @ctx.parse("{% if x == 1 %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::IS_TRUTHY
    assert_includes opcodes, LiquidIL::IL::COMPARE
  end

  def test_const_capture_folded
    template = @ctx.parse("{% capture foo %}hi{% endcapture %}{{ foo }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::PUSH_CAPTURE
    refute_includes opcodes, LiquidIL::IL::POP_CAPTURE
    assert_includes opcodes, LiquidIL::IL::CONST_STRING
    assert_includes opcodes, LiquidIL::IL::ASSIGN
  end

  def test_empty_write_raw_removed
    template = @ctx.parse("{{ '' }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::WRITE_RAW
    assert_includes opcodes, LiquidIL::IL::HALT
  end
end

class PartialInliningTest < Minitest::Test
  class MemoryFS
    attr_reader :reads

    def initialize(templates)
      @templates = templates
      @reads = Hash.new(0)
    end

    def read(name)
      @reads[name] += 1
      @templates[name]
    end
  end

  def test_literal_render_inlined_with_cached_partial
    fs = MemoryFS.new("snippet" => "Hi {{ target }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% render 'snippet' %}")

    inst = template.instructions.find { |i| i[0] == LiquidIL::IL::RENDER_PARTIAL }
    refute_nil inst
    compiled = inst[2]["__compiled_template__"]
    refute_nil compiled
    assert_equal "Hi World", template.render("target" => "World")
    assert_equal 1, fs.reads["snippet"]

    # Rendering again without a file system should still work via the compiled template
    opt.file_system = nil
    assert_equal "Hi Friend", template.render("target" => "Friend")
  end

  def test_render_with_with_clause_still_inlined
    fs = MemoryFS.new("snippet" => "Name: {{ snippet }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% render 'snippet' with helper %}")
    inst = template.instructions.find { |i| i[0] == LiquidIL::IL::RENDER_PARTIAL }
    refute_nil inst
    refute_nil inst[2]["__compiled_template__"]
    assert_equal "Name: helper!", template.render("helper" => "helper!")
  end

  def test_include_literal_inlined
    fs = MemoryFS.new("shared" => "Shared: {{ greeting }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% include 'shared' %}")
    inst = template.instructions.find { |i| i[0] == LiquidIL::IL::INCLUDE_PARTIAL }
    refute_nil inst
    refute_nil inst[2]["__compiled_template__"]
    assert_equal "Shared: hi", template.render("greeting" => "hi")
  end

  def test_dynamic_include_not_inlined
    fs = MemoryFS.new("shared" => "Hello")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% assign tpl = 'shared' %}{% include tpl %}")
    inst = template.instructions.find { |i| i[0] == LiquidIL::IL::INCLUDE_PARTIAL }
    refute_nil inst
    assert_nil inst[2]["__compiled_template__"]
    assert_equal "Hello", template.render
  end
end

class VariableOutputTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_string_variable
    assert_equal "hello", @ctx.render("{{ x }}", x: "hello")
  end

  def test_integer_variable
    assert_equal "42", @ctx.render("{{ x }}", x: 42)
  end

  def test_float_variable
    assert_equal "3.14", @ctx.render("{{ x }}", x: 3.14)
  end

  def test_nil_variable
    assert_equal "", @ctx.render("{{ x }}", x: nil)
  end

  def test_boolean_true
    assert_equal "true", @ctx.render("{{ x }}", x: true)
  end

  def test_boolean_false
    assert_equal "false", @ctx.render("{{ x }}", x: false)
  end

  def test_array_variable
    # Arrays render by joining elements
    assert_equal "123", @ctx.render("{{ x }}", x: [1, 2, 3])
  end

  def test_nested_property
    assert_equal "bar", @ctx.render("{{ x.foo }}", x: { "foo" => "bar" })
  end

  def test_array_index
    assert_equal "b", @ctx.render("{{ x[1] }}", x: ["a", "b", "c"])
  end

  def test_undefined_variable
    assert_equal "", @ctx.render("{{ undefined }}")
  end
end

class LiteralTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_string_literal
    assert_equal "hello", @ctx.render("{{ 'hello' }}")
  end

  def test_integer_literal
    assert_equal "42", @ctx.render("{{ 42 }}")
  end

  def test_float_literal
    assert_equal "3.14", @ctx.render("{{ 3.14 }}")
  end

  def test_true_literal
    assert_equal "true", @ctx.render("{{ true }}")
  end

  def test_false_literal
    assert_equal "false", @ctx.render("{{ false }}")
  end

  def test_nil_literal
    assert_equal "", @ctx.render("{{ nil }}")
  end

  def test_range_literal
    assert_equal "1..5", @ctx.render("{{ (1..5) }}")
  end
end

class FilterTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_upcase
    assert_equal "HELLO", @ctx.render("{{ 'hello' | upcase }}")
  end

  def test_downcase
    assert_equal "hello", @ctx.render("{{ 'HELLO' | downcase }}")
  end

  def test_capitalize
    assert_equal "Hello world", @ctx.render("{{ 'hello world' | capitalize }}")
  end

  def test_size
    assert_equal "5", @ctx.render("{{ 'hello' | size }}")
    assert_equal "3", @ctx.render("{{ x | size }}", x: [1, 2, 3])
  end

  def test_plus
    assert_equal "5", @ctx.render("{{ 2 | plus: 3 }}")
  end

  def test_minus
    assert_equal "7", @ctx.render("{{ 10 | minus: 3 }}")
  end

  def test_times
    assert_equal "12", @ctx.render("{{ 3 | times: 4 }}")
  end

  def test_divided_by
    assert_equal "5", @ctx.render("{{ 10 | divided_by: 2 }}")
  end

  def test_append
    assert_equal "hello world", @ctx.render("{{ 'hello' | append: ' world' }}")
  end

  def test_prepend
    assert_equal "hello world", @ctx.render("{{ 'world' | prepend: 'hello ' }}")
  end

  def test_default
    assert_equal "fallback", @ctx.render("{{ x | default: 'fallback' }}")
    assert_equal "value", @ctx.render("{{ x | default: 'fallback' }}", x: "value")
  end

  def test_filter_chain
    assert_equal "HELLO WORLD", @ctx.render("{{ 'hello' | append: ' world' | upcase }}")
  end

  def test_first
    assert_equal "a", @ctx.render("{{ x | first }}", x: ["a", "b", "c"])
  end

  def test_last
    assert_equal "c", @ctx.render("{{ x | last }}", x: ["a", "b", "c"])
  end

  def test_reverse
    assert_equal "cba", @ctx.render("{{ x | reverse | join: '' }}", x: ["a", "b", "c"])
  end

  def test_sort
    assert_equal "123", @ctx.render("{{ x | sort | join: '' }}", x: [3, 1, 2])
  end

  def test_join
    assert_equal "a-b-c", @ctx.render("{{ x | join: '-' }}", x: ["a", "b", "c"])
  end

  def test_split
    assert_equal "abc", @ctx.render("{{ 'a,b,c' | split: ',' | join: '' }}")
  end
end

class IfTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_if_true
    assert_equal "yes", @ctx.render("{% if true %}yes{% endif %}")
  end

  def test_if_false
    assert_equal "", @ctx.render("{% if false %}yes{% endif %}")
  end

  def test_if_variable_truthy
    assert_equal "yes", @ctx.render("{% if x %}yes{% endif %}", x: "hello")
  end

  def test_if_variable_falsy
    assert_equal "", @ctx.render("{% if x %}yes{% endif %}", x: nil)
  end

  def test_if_else
    assert_equal "no", @ctx.render("{% if false %}yes{% else %}no{% endif %}")
  end

  def test_if_elsif
    assert_equal "two", @ctx.render("{% if x == 1 %}one{% elsif x == 2 %}two{% endif %}", x: 2)
  end

  def test_if_elsif_else
    assert_equal "other", @ctx.render("{% if x == 1 %}one{% elsif x == 2 %}two{% else %}other{% endif %}", x: 3)
  end

  def test_unless
    assert_equal "yes", @ctx.render("{% unless false %}yes{% endunless %}")
    assert_equal "", @ctx.render("{% unless true %}yes{% endunless %}")
  end

  def test_comparison_eq
    assert_equal "yes", @ctx.render("{% if x == 1 %}yes{% endif %}", x: 1)
    assert_equal "", @ctx.render("{% if x == 1 %}yes{% endif %}", x: 2)
  end

  def test_comparison_ne
    assert_equal "yes", @ctx.render("{% if x != 1 %}yes{% endif %}", x: 2)
  end

  def test_comparison_lt
    assert_equal "yes", @ctx.render("{% if x < 5 %}yes{% endif %}", x: 3)
  end

  def test_comparison_gt
    assert_equal "yes", @ctx.render("{% if x > 5 %}yes{% endif %}", x: 7)
  end

  def test_and_operator
    assert_equal "yes", @ctx.render("{% if a and b %}yes{% endif %}", a: true, b: true)
    assert_equal "", @ctx.render("{% if a and b %}yes{% endif %}", a: true, b: false)
  end

  def test_or_operator
    assert_equal "yes", @ctx.render("{% if a or b %}yes{% endif %}", a: false, b: true)
    assert_equal "", @ctx.render("{% if a or b %}yes{% endif %}", a: false, b: false)
  end

  def test_contains
    assert_equal "yes", @ctx.render("{% if x contains 'ell' %}yes{% endif %}", x: "hello")
    assert_equal "yes", @ctx.render("{% if x contains 2 %}yes{% endif %}", x: [1, 2, 3])
  end
end

class ForTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_for_array
    assert_equal "123", @ctx.render("{% for i in x %}{{ i }}{% endfor %}", x: [1, 2, 3])
  end

  def test_for_range
    assert_equal "12345", @ctx.render("{% for i in (1..5) %}{{ i }}{% endfor %}")
  end

  def test_for_hash
    result = @ctx.render("{% for pair in x %}{{ pair[0] }}={{ pair[1] }} {% endfor %}", x: { "a" => 1, "b" => 2 })
    assert_includes result, "a=1"
    assert_includes result, "b=2"
  end

  def test_for_empty
    assert_equal "", @ctx.render("{% for i in x %}{{ i }}{% endfor %}", x: [])
  end

  def test_for_else
    assert_equal "empty", @ctx.render("{% for i in x %}{{ i }}{% else %}empty{% endfor %}", x: [])
  end

  def test_forloop_index
    assert_equal "123", @ctx.render("{% for i in x %}{{ forloop.index }}{% endfor %}", x: %w[a b c])
  end

  def test_forloop_index0
    assert_equal "012", @ctx.render("{% for i in x %}{{ forloop.index0 }}{% endfor %}", x: %w[a b c])
  end

  def test_forloop_first
    assert_equal "true false false ", @ctx.render("{% for i in x %}{{ forloop.first }} {% endfor %}", x: %w[a b c])
  end

  def test_forloop_last
    assert_equal "false false true ", @ctx.render("{% for i in x %}{{ forloop.last }} {% endfor %}", x: %w[a b c])
  end

  def test_forloop_length
    assert_equal "333", @ctx.render("{% for i in x %}{{ forloop.length }}{% endfor %}", x: %w[a b c])
  end

  def test_for_limit
    assert_equal "12", @ctx.render("{% for i in (1..5) limit:2 %}{{ i }}{% endfor %}")
  end

  def test_for_offset
    assert_equal "345", @ctx.render("{% for i in (1..5) offset:2 %}{{ i }}{% endfor %}")
  end

  def test_for_reversed
    assert_equal "321", @ctx.render("{% for i in x reversed %}{{ i }}{% endfor %}", x: [1, 2, 3])
  end
end

class AssignTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_assign_string
    assert_equal "hello", @ctx.render("{% assign x = 'hello' %}{{ x }}")
  end

  def test_assign_number
    assert_equal "42", @ctx.render("{% assign x = 42 %}{{ x }}")
  end

  def test_assign_variable
    assert_equal "world", @ctx.render("{% assign x = y %}{{ x }}", y: "world")
  end

  def test_assign_with_filter
    assert_equal "HELLO", @ctx.render("{% assign x = 'hello' | upcase %}{{ x }}")
  end
end

class CaptureTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_capture
    assert_equal "Hello World", @ctx.render("{% capture x %}Hello World{% endcapture %}{{ x }}")
  end

  def test_capture_with_variables
    assert_equal "Hi there", @ctx.render("{% capture x %}{{ greeting }} there{% endcapture %}{{ x }}", greeting: "Hi")
  end
end

class CaseTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_case_when
    template = "{% case x %}{% when 1 %}one{% when 2 %}two{% endcase %}"
    assert_equal "one", @ctx.render(template, x: 1)
    assert_equal "two", @ctx.render(template, x: 2)
    assert_equal "", @ctx.render(template, x: 3)
  end

  def test_case_else
    template = "{% case x %}{% when 1 %}one{% else %}other{% endcase %}"
    assert_equal "one", @ctx.render(template, x: 1)
    assert_equal "other", @ctx.render(template, x: 2)
  end

  def test_case_multiple_values
    template = "{% case x %}{% when 1, 2, 3 %}small{% else %}big{% endcase %}"
    assert_equal "small", @ctx.render(template, x: 2)
    assert_equal "big", @ctx.render(template, x: 10)
  end
end

class IncrementDecrementTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_increment
    assert_equal "0 1 2", @ctx.render("{% increment x %} {% increment x %} {% increment x %}")
  end

  def test_decrement
    assert_equal "-1 -2 -3", @ctx.render("{% decrement x %} {% decrement x %} {% decrement x %}")
  end
end

class CycleTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_cycle
    assert_equal "a b c a b", @ctx.render("{% cycle 'a', 'b', 'c' %} {% cycle 'a', 'b', 'c' %} {% cycle 'a', 'b', 'c' %} {% cycle 'a', 'b', 'c' %} {% cycle 'a', 'b', 'c' %}")
  end
end

class CommentTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_comment
    assert_equal "before  after", @ctx.render("before {% comment %}ignored{% endcomment %} after")
  end

  def test_inline_comment
    assert_equal "before  after", @ctx.render("before {% # this is ignored %} after")
  end
end

class RawTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_raw
    # Raw tag outputs literal Liquid syntax without parsing
    result = @ctx.render("{% raw %}{{ x }}{% endraw %}")
    assert_includes result, "x"
  end
end

class WhitespaceTrimTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_trim_right
    assert_equal "hello", @ctx.render("{{ 'hello' -}}  ")
  end

  def test_trim_right_on_tag
    assert_equal "yesafter", @ctx.render("{% if true -%}yes{%- endif %}after")
  end
end

class EchoTagTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_echo
    assert_equal "hello", @ctx.render("{% echo 'hello' %}")
  end

  def test_echo_with_filter
    assert_equal "HELLO", @ctx.render("{% echo 'hello' | upcase %}")
  end
end

# Simple file system for testing includes
class FileSystem
  def initialize(templates)
    @templates = templates
  end

  def read(name)
    @templates[name] || @templates["#{name}.liquid"]
  end
end

class IncludeRenderTest < Minitest::Test
  def setup
    @fs = FileSystem.new({
      "header" => "HEADER",
      "footer" => "FOOTER",
      "greeting" => "Hello {{ name }}",
      "item" => "Item: {{ item }}"
    })
    @ctx = LiquidIL::Context.new(file_system: @fs)
  end

  def test_include_simple
    assert_equal "HEADER", @ctx.render("{% include 'header' %}")
  end

  def test_include_with_variable
    assert_equal "Hello World", @ctx.render("{% include 'greeting' %}", name: "World")
  end

  def test_render_simple
    assert_equal "HEADER", @ctx.render("{% render 'header' %}")
  end
end

class ConstantPropagationTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_propagate_integer_constant
    # {% assign x = 5 %}{{ x | plus: 3 }} should fold to 8
    result = @ctx.render("{% assign x = 5 %}{{ x | plus: 3 }}")
    assert_equal "8", result
  end

  def test_propagate_string_constant
    # {% assign s = 'hello' %}{{ s | upcase }} should fold to HELLO
    result = @ctx.render("{% assign s = 'hello' %}{{ s | upcase }}")
    assert_equal "HELLO", result
  end

  def test_propagate_multiple_uses
    # Same constant used multiple times
    result = @ctx.render("{% assign x = 10 %}{{ x | plus: 1 }}-{{ x | plus: 2 }}")
    assert_equal "11-12", result
  end

  def test_no_propagate_after_reassignment
    # After reassignment, propagation should stop
    result = @ctx.render("{% assign x = 5 %}{% assign x = y %}{{ x }}", y: 10)
    assert_equal "10", result
  end

  def test_no_propagate_non_constant
    # Non-constant assignment should not be propagated
    result = @ctx.render("{% assign x = y %}{{ x | plus: 1 }}", y: 5)
    assert_equal "6", result
  end

  def test_constant_folding_chain
    # Multiple constants in a chain should fold
    result = @ctx.render("{% assign x = 2 %}{% assign y = 3 %}{{ x | plus: y }}")
    assert_equal "5", result
  end

  def test_il_shows_constant_propagation
    # Verify the IL is actually optimized
    compiler = LiquidIL::Compiler.new("{% assign x = 5 %}{{ x | plus: 3 }}", optimize: true)
    result = compiler.compile
    instructions = result[:instructions]

    # Should have WRITE_RAW "8" (folded), not FIND_VAR "x"
    write_raw = instructions.find { |i| i[0] == :WRITE_RAW && i[1] == "8" }
    assert write_raw, "Expected WRITE_RAW '8' from constant propagation + folding"

    # Should NOT have FIND_VAR "x"
    find_var_x = instructions.find { |i| i[0] == :FIND_VAR && i[1] == "x" }
    refute find_var_x, "FIND_VAR 'x' should be replaced by constant propagation"
  end
end

class LoopInvariantHoistingTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_hoist_invariant_variable
    # currency is loop-invariant, should be hoisted
    result = @ctx.render(
      "{% for i in items %}{{ currency }}{{ i }}{% endfor %}",
      items: [1, 2, 3], currency: "$"
    )
    assert_equal "$1$2$3", result
  end

  def test_loop_variable_not_hoisted
    # Loop variable 'item' should NOT be hoisted
    result = @ctx.render(
      "{% for item in items %}{{ item }}{% endfor %}",
      items: ["a", "b", "c"]
    )
    assert_equal "abc", result
  end

  def test_modified_variable_not_hoisted
    # Variable assigned inside loop should not be hoisted
    result = @ctx.render(
      "{% for i in items %}{% assign x = i %}{{ x }}{% endfor %}",
      items: [1, 2, 3]
    )
    assert_equal "123", result
  end

  def test_multiple_invariants
    # Multiple invariant variables
    result = @ctx.render(
      "{% for i in items %}{{ prefix }}{{ i }}{{ suffix }}{% endfor %}",
      items: [1, 2], prefix: "[", suffix: "]"
    )
    assert_equal "[1][2]", result
  end

  def test_il_shows_hoisting
    # Verify the IL shows hoisting happened
    compiler = LiquidIL::Compiler.new(
      "{% for i in items %}{{ currency }}{% endfor %}",
      optimize: true
    )
    result = compiler.compile
    instructions = result[:instructions]

    # Find FOR_INIT index
    for_init_idx = instructions.index { |i| i[0] == :FOR_INIT }
    assert for_init_idx, "Expected FOR_INIT instruction"

    # FIND_VAR "currency" and STORE_TEMP should come BEFORE FOR_INIT
    find_currency_idx = instructions.index { |i| i[0] == :FIND_VAR && i[1] == "currency" }
    store_temp_idx = instructions.index { |i| i[0] == :STORE_TEMP }

    if find_currency_idx && store_temp_idx
      assert find_currency_idx < for_init_idx, "FIND_VAR 'currency' should be hoisted before loop"
      assert store_temp_idx < for_init_idx, "STORE_TEMP should be before loop"
    end

    # Inside loop should use LOAD_TEMP, not FIND_VAR
    load_temp = instructions.find { |i| i[0] == :LOAD_TEMP }
    assert load_temp, "Expected LOAD_TEMP inside loop for hoisted variable"
  end

  def test_nested_loops_inner_invariant
    # Variable invariant in inner loop but defined in outer scope
    result = @ctx.render(
      "{% for i in outer %}{% for j in inner %}{{ prefix }}{% endfor %}{% endfor %}",
      outer: [1, 2], inner: [1, 2], prefix: "X"
    )
    assert_equal "XXXX", result
  end
end

class NestedLoopDynamicAccessTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_nested_loop_with_dynamic_bracket_access
    # This is a regression test for a bug where the second outer iteration
    # would receive corrupted data for the inner loop
    env = {
      "headers" => ["name", "email"],
      "rows" => [
        { "name" => "Alice", "email" => "alice@example.com" },
        { "name" => "Bob", "email" => "bob@example.com" }
      ]
    }

    template = '{% for row in rows %}[{% for header in headers %}{{ row[header] }}|{% endfor %}]{% endfor %}'
    result = @ctx.render(template, env)
    assert_equal "[Alice|alice@example.com|][Bob|bob@example.com|]", result
  end

  def test_nested_loop_with_dynamic_bracket_access_compiled
    # Same test but explicitly using the Ruby compiled version
    env = {
      "headers" => ["name", "email"],
      "rows" => [
        { "name" => "Alice", "email" => "alice@example.com" },
        { "name" => "Bob", "email" => "bob@example.com" }
      ]
    }

    template = '{% for row in rows %}[{% for header in headers %}{{ row[header] }}|{% endfor %}]{% endfor %}'
    ctx = LiquidIL::Context.new
    compiled = LiquidIL::Compiler::Ruby.compile(template, context: ctx)
    result = compiled.render(env)
    assert_equal "[Alice|alice@example.com|][Bob|bob@example.com|]", result
  end

  def test_nested_loop_three_iterations
    # Test with more outer iterations to ensure the bug is caught
    env = {
      "keys" => ["a", "b"],
      "items" => [
        { "a" => "1a", "b" => "1b" },
        { "a" => "2a", "b" => "2b" },
        { "a" => "3a", "b" => "3b" }
      ]
    }

    template = '{% for item in items %}{% for key in keys %}{{ item[key] }}{% endfor %}-{% endfor %}'
    result = @ctx.render(template, env)
    assert_equal "1a1b-2a2b-3a3b-", result
  end

  def test_vm_vs_compiled_nested_loop
    # Ensure VM and compiled give same results
    env = {
      "headers" => ["x", "y"],
      "rows" => [{ "x" => "1", "y" => "2" }, { "x" => "3", "y" => "4" }]
    }

    template = '{% for row in rows %}{{ row[headers[0]] }}{{ row[headers[1]] }}|{% endfor %}'

    ctx = LiquidIL::Context.new
    il = ctx.parse(template)

    # VM execution
    scope_vm = LiquidIL::Scope.new(env)
    vm_result = LiquidIL::VM.execute(il.instructions, scope_vm, spans: il.spans)

    # Compiled execution
    compiled = LiquidIL::Compiler::Ruby.compile(template, context: ctx)
    compiled_result = compiled.render(env)

    assert_equal vm_result, compiled_result, "VM and compiled results should match"
  end
end
