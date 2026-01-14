# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Focused tests for error handling
#
# These tests ensure that errors are properly reported with:
# - Correct partial name
# - Correct line number within the partial
# - No duplicated error messages
# - Proper behavior with render_errors enabled/disabled
#
class ErrorHandlingTest < Minitest::Test
  class MemoryFS
    def initialize(templates)
      @templates = templates
    end

    def read(name)
      @templates[name]
    end
  end

  def setup
    # Partial with an error on line 2
    @fs = MemoryFS.new("part" => "before\n{{ 'input' | truncate: 1.5 }}\nafter")
  end

  # Test basic error rendering in VM
  def test_vm_error_in_render_partial
    ctx = LiquidIL::Context.new(file_system: @fs)
    template = ctx.parse("start,{% render 'part' %},end", optimize: false)
    result = template.render({})

    # Should include partial name and correct line number
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part"
    assert_includes result, "line 2"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  def test_vm_error_in_include_partial
    ctx = LiquidIL::Context.new(file_system: @fs)
    template = ctx.parse("start,{% include 'part' %},end", optimize: false)
    result = template.render({})

    # Should include partial name and correct line number
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part"
    assert_includes result, "line 2"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  # Note: VM's render_errors is controlled internally, not exposed on public Context API
  # The compiled Ruby version exposes render_errors: parameter on render()

  # Test compiled Ruby error handling
  def test_compiled_error_in_render_partial
    ctx = LiquidIL::Context.new(file_system: @fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("start,{% render 'part' %},end")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Should include partial name and correct line number
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part", "Should include partial name"
    assert_includes result, "line 2", "Should report line 2 (where error occurs in partial)"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  def test_compiled_error_in_include_partial
    ctx = LiquidIL::Context.new(file_system: @fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("start,{% include 'part' %},end")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Should include partial name and correct line number
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part", "Should include partial name"
    assert_includes result, "line 2", "Should report line 2 (where error occurs in partial)"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  def test_compiled_raises_when_render_errors_disabled
    ctx = LiquidIL::Context.new(file_system: @fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("start,{% render 'part' %},end")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)

    assert_raises(LiquidIL::RuntimeError) do
      compiled.render({}, render_errors: false)
    end
  end

  # Test no duplicate error messages
  def test_no_duplicate_errors
    ctx = LiquidIL::Context.new(file_system: @fs)
    template = ctx.parse("{% render 'part' %}", optimize: false)
    result = template.render({})

    # Count occurrences of "Liquid error" - should be exactly 1
    error_count = result.scan(/Liquid error/).length
    assert_equal 1, error_count, "Should have exactly 1 error message, not #{error_count}"
  end

  def test_compiled_no_duplicate_errors
    ctx = LiquidIL::Context.new(file_system: @fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("{% render 'part' %}")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Count occurrences of "Liquid error" - should be exactly 1
    error_count = result.scan(/Liquid error/).length
    assert_equal 1, error_count, "Should have exactly 1 error message, not #{error_count}"
  end

  # Test error with prefix and suffix content
  def test_error_preserves_surrounding_content
    ctx = LiquidIL::Context.new(file_system: @fs)
    template = ctx.parse("PREFIX{% render 'part' %}SUFFIX", optimize: false)
    result = template.render({})

    assert_match(/\APREFIX/, result, "Should start with PREFIX")
    assert_match(/SUFFIX\z/, result, "Should end with SUFFIX")
  end

  def test_compiled_error_preserves_surrounding_content
    ctx = LiquidIL::Context.new(file_system: @fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("PREFIX{% render 'part' %}SUFFIX")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    assert_match(/\APREFIX/, result, "Should start with PREFIX")
    assert_match(/SUFFIX\z/, result, "Should end with SUFFIX")
  end

  # Test error on first line of partial
  def test_error_on_first_line
    fs = MemoryFS.new("err" => "{{ 'x' | truncate: 1.5 }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% render 'err' %}", optimize: false)
    result = template.render({})

    assert_includes result, "line 1"
    assert_includes result, "err"
  end

  # Test nested partial errors
  def test_nested_partial_error
    fs = MemoryFS.new(
      "outer" => "outer:{% render 'inner' %}",
      "inner" => "inner\n{{ 'x' | truncate: 1.5 }}"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% render 'outer' %}", optimize: false)
    result = template.render({})

    # Error should be attributed to inner partial, line 2
    assert_includes result, "outer:inner"
    assert_includes result, "Liquid error"
    assert_includes result, "inner"  # Should mention inner partial
    assert_includes result, "line 2"
  end

  # Test compiled nested partial errors
  def test_compiled_nested_partial_error
    fs = MemoryFS.new(
      "outer" => "outer:{% render 'inner' %}",
      "inner" => "inner\n{{ 'x' | truncate: 1.5 }}"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("{% render 'outer' %}")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Error should be attributed to inner partial, line 2
    assert_includes result, "outer:inner"
    assert_includes result, "Liquid error"
    assert_includes result, "inner", "Should mention inner partial"
    assert_includes result, "line 2", "Should report line 2 in inner partial"
  end

  # Test 3 levels deep - main -> level1 -> level2 -> level3 (error)
  def test_vm_three_level_nested_error
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2[{% render 'level3' %}]",
      "level3" => "L3\nline2\n{{ 'x' | truncate: 1.5 }}\nline4"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("start{% render 'level1' %}end", optimize: false)
    result = template.render({})

    # Should have content from all levels before error
    assert_includes result, "startL1[L2[L3"
    assert_includes result, "line2"
    assert_includes result, "Liquid error"
    assert_includes result, "level3", "Should mention level3 partial"
    assert_includes result, "line 3", "Error is on line 3 of level3"
    assert_includes result, "line4"  # Content after error
    assert_includes result, "]]end"  # Closing from level1 and level2
  end

  def test_compiled_three_level_nested_error
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2[{% render 'level3' %}]",
      "level3" => "L3\nline2\n{{ 'x' | truncate: 1.5 }}\nline4"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("start{% render 'level1' %}end")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Should have content from all levels before error
    assert_includes result, "startL1[L2[L3"
    assert_includes result, "line2"
    assert_includes result, "Liquid error"
    assert_includes result, "level3", "Should mention level3 partial"
    assert_includes result, "line 3", "Error is on line 3 of level3"
    assert_includes result, "line4"  # Content after error
    assert_includes result, "]]end"  # Closing from level1 and level2
  end

  # Test error at middle level (level2) in 3-level nesting
  def test_vm_error_at_middle_level
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2-before\n{{ 'x' | truncate: 1.5 }}\nL2-after",
      "level3" => "L3-content"  # Not reached due to error in level2
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("start{% render 'level1' %}end", optimize: false)
    result = template.render({})

    assert_includes result, "startL1[L2-before"
    assert_includes result, "Liquid error"
    assert_includes result, "level2", "Should mention level2 partial"
    assert_includes result, "line 2", "Error is on line 2 of level2"
    assert_includes result, "L2-after"
    assert_includes result, "]end"
  end

  def test_compiled_error_at_middle_level
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2-before\n{{ 'x' | truncate: 1.5 }}\nL2-after",
      "level3" => "L3-content"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("start{% render 'level1' %}end")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    assert_includes result, "startL1[L2-before"
    assert_includes result, "Liquid error"
    assert_includes result, "level2", "Should mention level2 partial"
    assert_includes result, "line 2", "Error is on line 2 of level2"
    assert_includes result, "L2-after"
    assert_includes result, "]end"
  end

  # Test multiple errors in nested partials (each partial has an error)
  def test_vm_multiple_nested_errors
    fs = MemoryFS.new(
      "outer" => "outer[{{ 'a' | truncate: 1.5 }}]{% render 'inner' %}",
      "inner" => "inner[{{ 'b' | truncate: 1.5 }}]"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% render 'outer' %}", optimize: false)
    result = template.render({})

    # Should have exactly 2 error messages
    error_count = result.scan(/Liquid error/).length
    assert_equal 2, error_count, "Should have exactly 2 error messages, got #{error_count}"

    # First error in outer, second in inner
    assert_includes result, "outer line 1"
    assert_includes result, "inner line 1"
  end

  def test_compiled_multiple_nested_errors
    fs = MemoryFS.new(
      "outer" => "outer[{{ 'a' | truncate: 1.5 }}]{% render 'inner' %}",
      "inner" => "inner[{{ 'b' | truncate: 1.5 }}]"
    )
    ctx = LiquidIL::Context.new(file_system: fs)
    opt = LiquidIL::Optimizer.optimize(ctx)
    il_template = opt.parse("{% render 'outer' %}")
    compiled = LiquidIL::Compiler::Ruby.compile(il_template)
    result = compiled.render({}, render_errors: true)

    # Should have exactly 2 error messages
    error_count = result.scan(/Liquid error/).length
    assert_equal 2, error_count, "Should have exactly 2 error messages, got #{error_count}"
  end
end
