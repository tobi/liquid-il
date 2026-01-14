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
end
