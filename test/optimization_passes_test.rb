# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Comprehensive tests for each IL optimization pass
#
# The optimizer runs passes in this order:
#  0. inline_simple_partials
#  1. fold_const_ops
#  2. fold_const_filters
#  3. fold_const_writes
#  4. collapse_const_paths
#  5. collapse_find_var_paths
#  6. remove_redundant_is_truthy
#  7. remove_noops
#  8. remove_jump_to_next_label
#  9. merge_raw_writes
# 10. remove_unreachable
# 11. merge_raw_writes (again)
# 12. fold_const_captures
# 13. remove_empty_raw_writes
# 14. propagate_constants
# 15. fold_const_filters/writes/merge (again after propagation)
# 16. hoist_loop_invariants
# 17. cache_repeated_lookups
# 18. value_numbering
# 19. RegisterAllocator.optimize

class Pass0InlineSimplePartialsTest < Minitest::Test
  class MemoryFS
    def initialize(templates)
      @templates = templates
    end

    def read(name)
      @templates[name]
    end
  end

  def test_render_literal_fully_inlined
    # render creates isolated scope - partial is fully inlined with PUSH_SCOPE/POP_SCOPE
    fs = MemoryFS.new("part" => "hello")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% render 'part' %}")

    # Simple renders are fully inlined - no RENDER_PARTIAL instruction
    assert_nil template.instructions.find { |i| i[0] == LiquidIL::IL::RENDER_PARTIAL }
    assert_equal "hello", template.render
  end

  def test_render_inlining_uses_scope_wrapper
    # Inlined renders use PUSH_SCOPE/POP_SCOPE for scope management
    fs = MemoryFS.new("part" => "hello")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% render 'part' %}")

    opcodes = template.instructions.map(&:first)
    assert_includes opcodes, LiquidIL::IL::PUSH_SCOPE
    assert_includes opcodes, LiquidIL::IL::POP_SCOPE
    assert_equal "hello", template.render
  end

  def test_include_literal_fully_inlined
    # include shares caller's scope - should be fully inlined without scope isolation
    fs = MemoryFS.new("part" => "x={{ x }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% assign x = 'outer' %}{% include 'part' %}")

    # INCLUDE_PARTIAL should NOT be present (fully inlined)
    assert_nil template.instructions.find { |i| i[0] == LiquidIL::IL::INCLUDE_PARTIAL }
    # Outer x should be visible
    assert_equal "x=outer", template.render
  end

  def test_include_with_args_inlined
    fs = MemoryFS.new("greet" => "Hello {{ name }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% include 'greet', name: 'World' %}")

    assert_nil template.instructions.find { |i| i[0] == LiquidIL::IL::INCLUDE_PARTIAL }
    assert_equal "Hello World", template.render
  end

  def test_dynamic_include_not_inlined
    # Dynamic partial names cannot be inlined
    fs = MemoryFS.new("dynamic" => "content")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% assign tpl = 'dynamic' %}{% include tpl %}")

    # Should have INCLUDE_PARTIAL without compiled template
    include_inst = template.instructions.find { |i| i[0] == LiquidIL::IL::INCLUDE_PARTIAL }
    refute_nil include_inst
    assert_nil include_inst[2]["__compiled_template__"]
    assert_equal "content", template.render
  end

  def test_render_with_for_clause_not_fully_inlined
    # render with for clause keeps RENDER_PARTIAL instruction
    fs = MemoryFS.new("item" => "[{{ item }}]")
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    template = opt.parse("{% render 'item' for items %}")

    render_inst = template.instructions.find { |i| i[0] == LiquidIL::IL::RENDER_PARTIAL }
    refute_nil render_inst
    refute_nil render_inst[2]["__compiled_template__"]
    assert_equal "[a][b][c]", template.render("items" => %w[a b c])
  end
end

class Pass1FoldConstOpsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_const_is_truthy_folded
    # CONST + IS_TRUTHY should become CONST_TRUE or CONST_FALSE
    template = @ctx.parse("{% if 'hello' %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::IS_TRUTHY
    assert_equal "yes", template.render
  end

  def test_const_bool_not_folded
    template = @ctx.parse("{% unless true %}a{% else %}b{% endunless %}", optimize: true)
    assert_equal "b", template.render
  end

  def test_const_compare_equals_folded
    template = @ctx.parse("{% if 1 == 1 %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Comparison should be folded away
    refute_includes opcodes, LiquidIL::IL::COMPARE
    assert_equal "yes", template.render
  end

  def test_const_compare_not_equals_folded
    template = @ctx.parse("{% if 1 != 2 %}yes{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end

  def test_const_compare_less_than_folded
    template = @ctx.parse("{% if 1 < 2 %}yes{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end

  def test_const_compare_greater_than_folded
    template = @ctx.parse("{% if 2 > 1 %}yes{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end

  def test_const_case_compare_folded
    template = @ctx.parse("{% case 'a' %}{% when 'a' %}match{% endcase %}", optimize: true)
    assert_equal "match", template.render
  end

  def test_const_contains_folded
    template = @ctx.parse("{% if 'hello' contains 'ell' %}yes{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end

  def test_const_jump_if_false_eliminated
    template = @ctx.parse("{% if false %}no{% else %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_FALSE
    assert_equal "yes", template.render
  end

  def test_const_jump_if_true_eliminated
    template = @ctx.parse("{% if true %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_TRUE
    assert_equal "yes", template.render
  end
end

class Pass2FoldConstFiltersTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def assert_filter_folded(template_str, expected)
    template = @ctx.parse(template_str, optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::CALL_FILTER, "Filter should be folded for: #{template_str}"
    assert_equal expected, template.render
  end

  def test_upcase_folded
    assert_filter_folded "{{ 'hello' | upcase }}", "HELLO"
  end

  def test_downcase_folded
    assert_filter_folded "{{ 'HELLO' | downcase }}", "hello"
  end

  def test_capitalize_folded
    assert_filter_folded "{{ 'hello' | capitalize }}", "Hello"
  end

  def test_size_folded
    assert_filter_folded "{{ 'hello' | size }}", "5"
  end

  def test_append_folded
    assert_filter_folded "{{ 'hello' | append: ' world' }}", "hello world"
  end

  def test_prepend_folded
    assert_filter_folded "{{ 'world' | prepend: 'hello ' }}", "hello world"
  end

  def test_plus_folded
    assert_filter_folded "{{ 1 | plus: 2 }}", "3"
  end

  def test_minus_folded
    assert_filter_folded "{{ 5 | minus: 2 }}", "3"
  end

  def test_times_folded
    assert_filter_folded "{{ 3 | times: 4 }}", "12"
  end

  def test_divided_by_folded
    assert_filter_folded "{{ 10 | divided_by: 2 }}", "5"
  end

  def test_modulo_folded
    assert_filter_folded "{{ 10 | modulo: 3 }}", "1"
  end

  def test_abs_folded
    assert_filter_folded "{{ -5 | abs }}", "5"
  end

  def test_floor_folded
    assert_filter_folded "{{ 4.6 | floor }}", "4"
  end

  def test_ceil_folded
    assert_filter_folded "{{ 4.1 | ceil }}", "5"
  end

  def test_round_folded
    assert_filter_folded "{{ 4.5 | round }}", "5"
  end

  def test_strip_folded
    assert_filter_folded "{{ '  hello  ' | strip }}", "hello"
  end

  def test_lstrip_folded
    assert_filter_folded "{{ '  hello' | lstrip }}", "hello"
  end

  def test_rstrip_folded
    assert_filter_folded "{{ 'hello  ' | rstrip }}", "hello"
  end

  def test_json_folded
    assert_filter_folded "{{ 'hello' | json }}", '"hello"'
  end

  def test_chained_filters_folded
    # Both upcase and append are in the safe fold list
    assert_filter_folded "{{ 'hello' | upcase | append: '!' }}", "HELLO!"
  end

  def test_slice_folded
    assert_filter_folded "{{ 'hello' | slice: 0, 3 }}", "hel"
  end

  def test_default_folded
    assert_filter_folded "{{ nil | default: 'fallback' }}", "fallback"
  end
end

class Pass3FoldConstWritesTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_const_string_write_folded
    template = @ctx.parse("{{ 'hello' }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::WRITE_VALUE
    assert_includes opcodes, LiquidIL::IL::WRITE_RAW
  end

  def test_const_int_write_folded
    template = @ctx.parse("{{ 42 }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::WRITE_VALUE
    assert_includes opcodes, LiquidIL::IL::WRITE_RAW
    assert_equal "42", template.render
  end

  def test_const_true_write_folded
    template = @ctx.parse("{{ true }}", optimize: true)
    assert_equal "true", template.render
  end

  def test_const_false_write_folded
    template = @ctx.parse("{{ false }}", optimize: true)
    assert_equal "false", template.render
  end

  def test_const_nil_write_folded
    template = @ctx.parse("{{ nil }}", optimize: true)
    assert_equal "", template.render
  end
end

class Pass4CollapseConstPathsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_chained_lookups_collapsed
    template = @ctx.parse("{{ user.profile.name }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Should have FIND_VAR_PATH or WRITE_VAR_PATH (fused), not multiple LOOKUP_CONST_KEY
    has_var_path = opcodes.include?(LiquidIL::IL::FIND_VAR_PATH) || opcodes.include?(LiquidIL::IL::WRITE_VAR_PATH)
    assert has_var_path, "Expected either FIND_VAR_PATH or WRITE_VAR_PATH in opcodes"
    refute_includes opcodes, LiquidIL::IL::LOOKUP_CONST_KEY

    assert_equal "Alice", template.render("user" => { "profile" => { "name" => "Alice" } })
  end

  def test_deep_path_collapsed
    template = @ctx.parse("{{ a.b.c.d.e }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Should have FIND_VAR_PATH or WRITE_VAR_PATH (fused)
    has_var_path = opcodes.include?(LiquidIL::IL::FIND_VAR_PATH) || opcodes.include?(LiquidIL::IL::WRITE_VAR_PATH)
    assert has_var_path, "Expected either FIND_VAR_PATH or WRITE_VAR_PATH in opcodes"
    refute_includes opcodes, LiquidIL::IL::LOOKUP_CONST_KEY
  end
end

class Pass5CollapseFindVarPathsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_find_var_plus_path_collapsed
    # Need 2+ keys for LOOKUP_CONST_PATH to be created, then merged with FIND_VAR
    template = @ctx.parse("{{ x.y.z }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Should have FIND_VAR_PATH or WRITE_VAR_PATH (fused)
    has_var_path = opcodes.include?(LiquidIL::IL::FIND_VAR_PATH) || opcodes.include?(LiquidIL::IL::WRITE_VAR_PATH)
    assert has_var_path, "Expected either FIND_VAR_PATH or WRITE_VAR_PATH in opcodes"
    refute_includes opcodes, LiquidIL::IL::FIND_VAR
    refute_includes opcodes, LiquidIL::IL::LOOKUP_CONST_PATH
    assert_equal "value", template.render("x" => { "y" => { "z" => "value" } })
  end

  def test_single_key_not_collapsed
    # Single key stays as FIND_VAR + LOOKUP_CONST_KEY (no LOOKUP_CONST_PATH to merge)
    template = @ctx.parse("{{ x.y }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    assert_includes opcodes, LiquidIL::IL::FIND_VAR
    assert_includes opcodes, LiquidIL::IL::LOOKUP_CONST_KEY
  end
end

class Pass6RemoveRedundantIsTruthyTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_is_truthy_after_compare_removed
    template = @ctx.parse("{% if x == 1 %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::IS_TRUTHY
    assert_includes opcodes, LiquidIL::IL::COMPARE
    assert_equal "yes", template.render("x" => 1)
  end

  def test_is_truthy_after_case_compare_removed
    template = @ctx.parse("{% case x %}{% when 1 %}one{% endcase %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::IS_TRUTHY
    assert_equal "one", template.render("x" => 1)
  end

  def test_is_truthy_after_contains_removed
    template = @ctx.parse("{% if items contains 'a' %}yes{% endif %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::IS_TRUTHY
    assert_includes opcodes, LiquidIL::IL::CONTAINS
    assert_equal "yes", template.render("items" => %w[a b])
  end

  def test_unless_keeps_is_truthy
    # unless uses IS_TRUTHY + JUMP_IF_TRUE, not BOOL_NOT
    # IS_TRUTHY is only removed after boolean-producing ops (COMPARE, etc.)
    template = @ctx.parse("{% unless x %}yes{% endunless %}", optimize: true)
    # Should still work correctly
    assert_equal "yes", template.render("x" => false)
    assert_equal "", template.render("x" => true)
  end
end

class Pass7RemoveNoopsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_comment_produces_no_noop
    template = @ctx.parse("{% comment %}ignored{% endcomment %}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::NOOP
  end

  def test_empty_template_has_only_halt
    template = @ctx.parse("", optimize: true)
    # Should just have HALT
    assert_equal [[LiquidIL::IL::HALT]], template.instructions
  end
end

class Pass8RemoveJumpToNextLabelTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_jump_to_immediate_label_removed
    # {% if false %}a{% endif %} would generate JUMP to next label
    template = @ctx.parse("{% if false %}a{% endif %}", optimize: true)
    # After optimization, the false branch is eliminated
    opcodes = template.instructions.map(&:first)
    # Should not have any conditional jumps since condition is constant
    refute_includes opcodes, LiquidIL::IL::JUMP_IF_FALSE
    assert_equal "", template.render
  end
end

class Pass9MergeRawWritesTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_adjacent_raw_writes_merged
    template = @ctx.parse("abc{{ 'def' }}ghi", optimize: true)
    # All three parts should be merged into one WRITE_RAW
    raw_writes = template.instructions.select { |i| i[0] == LiquidIL::IL::WRITE_RAW }
    assert_equal 1, raw_writes.size
    assert_equal "abcdefghi", raw_writes[0][1]
  end

  def test_multiple_raw_writes_merged
    template = @ctx.parse("{{ '1' }}{{ '2' }}{{ '3' }}{{ '4' }}", optimize: true)
    raw_writes = template.instructions.select { |i| i[0] == LiquidIL::IL::WRITE_RAW }
    assert_equal 1, raw_writes.size
    assert_equal "1234", raw_writes[0][1]
  end
end

class Pass10RemoveUnreachableTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_code_after_halt_removed
    # Code after HALT is unreachable and should be removed
    # This tests the basic mechanism - HALT followed by more code
    template = @ctx.parse("{% if true %}yes{% endif %}", optimize: true)
    output = template.render
    assert_equal "yes", output

    # Should only have WRITE_RAW "yes" and HALT
    opcodes = template.instructions.map(&:first)
    assert_includes opcodes, LiquidIL::IL::WRITE_RAW
    assert_includes opcodes, LiquidIL::IL::HALT
  end

  def test_constant_if_produces_correct_output
    # Even if else branch exists in IL, output should be correct
    template = @ctx.parse("{% if true %}yes{% else %}never{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end

  def test_false_condition_takes_else_branch
    template = @ctx.parse("{% if false %}never{% else %}yes{% endif %}", optimize: true)
    assert_equal "yes", template.render
  end
end

class Pass12FoldConstCapturesTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_const_capture_folded
    template = @ctx.parse("{% capture foo %}hello{% endcapture %}{{ foo }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::PUSH_CAPTURE
    refute_includes opcodes, LiquidIL::IL::POP_CAPTURE
    # Should assign constant directly
    assert_includes opcodes, LiquidIL::IL::CONST_STRING
    assert_equal "hello", template.render
  end

  def test_capture_with_variable_not_folded
    template = @ctx.parse("{% capture foo %}hello {{ name }}{% endcapture %}{{ foo }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Should still have capture since body depends on variable
    assert_includes opcodes, LiquidIL::IL::PUSH_CAPTURE
    assert_equal "hello world", template.render("name" => "world")
  end

  def test_nested_const_capture_folded
    template = @ctx.parse("{% capture a %}{% capture b %}inner{% endcapture %}{{ b }}{% endcapture %}{{ a }}", optimize: true)
    assert_equal "inner", template.render
  end
end

class Pass13RemoveEmptyRawWritesTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_empty_string_write_removed
    template = @ctx.parse("{{ '' }}", optimize: true)
    raw_writes = template.instructions.select { |i| i[0] == LiquidIL::IL::WRITE_RAW }
    assert_empty raw_writes
  end

  def test_nil_write_doesnt_leave_empty
    template = @ctx.parse("{{ nil }}", optimize: true)
    raw_writes = template.instructions.select { |i| i[0] == LiquidIL::IL::WRITE_RAW && i[1] == "" }
    assert_empty raw_writes
  end
end

class Pass14PropagateConstantsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_assigned_constant_propagated
    template = @ctx.parse("{% assign x = 'hello' %}{{ x }}", optimize: true)
    # x should be replaced with the constant
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::FIND_VAR
    assert_equal "hello", template.render
  end

  def test_propagation_stops_at_reassignment
    template = @ctx.parse("{% assign x = 1 %}{% assign x = 2 %}{{ x }}", optimize: true)
    assert_equal "2", template.render
  end

  def test_propagation_stops_at_loop
    template = @ctx.parse("{% assign x = 1 %}{% for i in (1..2) %}{{ x }}{% endfor %}", optimize: true)
    assert_equal "11", template.render
  end

  def test_propagation_enables_filter_folding
    template = @ctx.parse("{% assign x = 'hello' %}{{ x | upcase }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    # Filter should be folded since x is known constant
    refute_includes opcodes, LiquidIL::IL::CALL_FILTER
    assert_equal "HELLO", template.render
  end
end

class Pass16HoistLoopInvariantsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_invariant_lookup_hoisted
    template = @ctx.parse("{% for i in items %}{{ prefix }}{{ i }}{% endfor %}", optimize: true)
    # prefix lookup should be hoisted before the loop
    assert_equal "X1X2X3", template.render("items" => [1, 2, 3], "prefix" => "X")
  end

  def test_loop_variable_not_hoisted
    template = @ctx.parse("{% for item in items %}{{ item }}{% endfor %}", optimize: true)
    assert_equal "abc", template.render("items" => %w[a b c])
  end

  def test_forloop_property_not_hoisted
    template = @ctx.parse("{% for i in items %}{{ forloop.index }}{% endfor %}", optimize: true)
    assert_equal "123", template.render("items" => [1, 2, 3])
  end

  def test_nested_loop_invariant_hoisted
    template = @ctx.parse("{% for i in outer %}{% for j in inner %}{{ prefix }}{% endfor %}{% endfor %}", optimize: true)
    assert_equal "XXXX", template.render("outer" => [1, 2], "inner" => [1, 2], "prefix" => "X")
  end
end

class Pass17CacheRepeatedLookupsTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_repeated_lookup_cached
    template = @ctx.parse("{{ x }}{{ x }}{{ x }}", optimize: true)
    # Should have STORE_TEMP and LOAD_TEMP for caching
    opcodes = template.instructions.map(&:first)
    assert_includes opcodes, LiquidIL::IL::STORE_TEMP
    assert_includes opcodes, LiquidIL::IL::LOAD_TEMP
    assert_equal "aaa", template.render("x" => "a")
  end

  def test_single_lookup_not_cached
    template = @ctx.parse("{{ x }}", optimize: true)
    opcodes = template.instructions.map(&:first)
    refute_includes opcodes, LiquidIL::IL::STORE_TEMP
    assert_equal "a", template.render("x" => "a")
  end
end

class Pass19RegisterAllocatorTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_temp_reuse_basic
    # Multiple temps should be reused when possible
    template = @ctx.parse("{{ a }}{{ a }}{{ b }}{{ b }}", optimize: true)
    # Should produce correct output despite temp reuse
    assert_equal "aabb", template.render("a" => "a", "b" => "b")
  end

  def test_nested_loop_temps_not_collide
    # This was a bug: nested loops had temp register collision
    template = @ctx.parse(<<~LIQUID, optimize: true)
      {% for row in data %}
        {% for col in headers %}{{ row[col] }}{% endfor %}
      {% endfor %}
    LIQUID

    data = [
      { "name" => "Alice", "age" => "30" },
      { "name" => "Bob", "age" => "25" }
    ]
    result = template.render("data" => data, "headers" => %w[name age])
    assert_includes result, "Alice"
    assert_includes result, "Bob"
    assert_includes result, "30"
    assert_includes result, "25"
  end

  def test_case_statement_temps_preserved
    # Case/when with temp for flag should work correctly
    template = @ctx.parse(<<~LIQUID, optimize: true)
      {% case x %}
      {% when 'a' %}A
      {% when 'b' %}B
      {% else %}other
      {% endcase %}
    LIQUID

    assert_includes template.render("x" => "a"), "A"
    assert_includes template.render("x" => "b"), "B"
    assert_includes template.render("x" => "c"), "other"
  end

  def test_outer_loop_variable_survives_inner_loop
    # Variable defined before outer loop should survive inner loop iterations
    template = @ctx.parse(<<~LIQUID, optimize: true)
      {% for outer in outer_items %}
        {% for inner in inner_items %}
          {{ prefix }}
        {% endfor %}
      {% endfor %}
    LIQUID

    result = template.render(
      "outer_items" => [1, 2],
      "inner_items" => [1, 2],
      "prefix" => "X"
    )
    assert_equal 4, result.scan("X").size
  end
end

# Test that optimizations don't break semantics
class OptimizationCorrectnessTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
    @opt_ctx = LiquidIL::Optimizer.optimize(LiquidIL::Context.new)
  end

  def assert_same_output(template_str, assigns = {})
    unopt = @ctx.parse(template_str, optimize: false)
    opt = @opt_ctx.parse(template_str)

    unopt_result = unopt.render(assigns)
    opt_result = opt.render(assigns)

    assert_equal unopt_result, opt_result, "Optimization changed output for: #{template_str}"
  end

  def test_simple_output
    assert_same_output "{{ x }}", "x" => "hello"
  end

  def test_filter_chain
    assert_same_output "{{ x | upcase | reverse }}", "x" => "hello"
  end

  def test_if_else
    assert_same_output "{% if x %}yes{% else %}no{% endif %}", "x" => true
    assert_same_output "{% if x %}yes{% else %}no{% endif %}", "x" => false
  end

  def test_for_loop
    assert_same_output "{% for i in items %}{{ i }}{% endfor %}", "items" => [1, 2, 3]
  end

  def test_nested_for_loops
    assert_same_output(
      "{% for i in outer %}{% for j in inner %}{{ i }}-{{ j }} {% endfor %}{% endfor %}",
      "outer" => [1, 2], "inner" => %w[a b]
    )
  end

  def test_capture
    assert_same_output "{% capture x %}hello{% endcapture %}{{ x }}"
  end

  def test_assign_and_use
    assert_same_output "{% assign x = 'world' %}hello {{ x }}"
  end

  def test_case_when
    assert_same_output "{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", "x" => 1
    assert_same_output "{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", "x" => 2
    assert_same_output "{% case x %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}", "x" => 3
  end

  def test_nested_property_access
    assert_same_output "{{ user.profile.name }}", "user" => { "profile" => { "name" => "Alice" } }
  end

  def test_array_access
    assert_same_output "{{ items[1] }}", "items" => %w[a b c]
  end

  def test_increment_decrement
    assert_same_output "{% increment x %}{% increment x %}{% decrement x %}"
  end

  def test_tablerow
    assert_same_output "{% tablerow i in items %}{{ i }}{% endtablerow %}", "items" => [1, 2, 3]
  end
end
