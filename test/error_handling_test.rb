# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Focused tests for error handling in the structured compiler.
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
    @fs = MemoryFS.new("part" => "before\n{{ 'input' | truncate: 1.5 }}\nafter")
  end

  def compile(source, fs: @fs)
    ctx = LiquidIL::Context.new(file_system: fs)
    ctx.parse(source)
  end

  def test_error_in_render_partial
    result = compile("start,{% render 'part' %},end").render({})
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  def test_error_in_include_partial
    result = compile("start,{% include 'part' %},end").render({})
    assert_includes result, "start,before"
    assert_includes result, "Liquid error"
    assert_includes result, "part"
    assert_includes result, "invalid integer"
    assert_includes result, "after,end"
  end

  def test_no_duplicate_errors
    result = compile("{% render 'part' %}").render({})
    error_count = result.scan(/Liquid error/).length
    assert_equal 1, error_count, "Should have exactly 1 error message, not #{error_count}"
  end

  def test_error_preserves_surrounding_content
    result = compile("PREFIX{% render 'part' %}SUFFIX").render({})
    assert_match(/\APREFIX/, result)
    assert_match(/SUFFIX\z/, result)
  end

  def test_error_on_first_line
    fs = MemoryFS.new("err" => "{{ 'x' | truncate: 1.5 }}")
    result = compile("{% render 'err' %}", fs: fs).render({})
    assert_includes result, "line 1"
    assert_includes result, "err"
  end

  def test_nested_partial_error
    fs = MemoryFS.new(
      "outer" => "outer:{% render 'inner' %}",
      "inner" => "inner\n{{ 'x' | truncate: 1.5 }}"
    )
    result = compile("{% render 'outer' %}", fs: fs).render({})
    assert_includes result, "outer:inner"
    assert_includes result, "Liquid error"
    assert_includes result, "inner"
  end

  def test_three_level_nested_error
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2[{% render 'level3' %}]",
      "level3" => "L3\nline2\n{{ 'x' | truncate: 1.5 }}\nline4"
    )
    result = compile("start{% render 'level1' %}end", fs: fs).render({})
    assert_includes result, "startL1[L2[L3"
    assert_includes result, "line2"
    assert_includes result, "Liquid error"
    assert_includes result, "level3"
    assert_includes result, "line4"
    assert_includes result, "]]end"
  end

  def test_error_at_middle_level
    fs = MemoryFS.new(
      "level1" => "L1[{% render 'level2' %}]",
      "level2" => "L2-before\n{{ 'x' | truncate: 1.5 }}\nL2-after"
    )
    result = compile("start{% render 'level1' %}end", fs: fs).render({})
    assert_includes result, "startL1[L2-before"
    assert_includes result, "Liquid error"
    assert_includes result, "level2"
    assert_includes result, "L2-after"
    assert_includes result, "]end"
  end

  def test_multiple_nested_errors
    fs = MemoryFS.new(
      "outer" => "outer[{{ 'a' | truncate: 1.5 }}]{% render 'inner' %}",
      "inner" => "inner[{{ 'b' | truncate: 1.5 }}]"
    )
    result = compile("{% render 'outer' %}", fs: fs).render({})
    error_count = result.scan(/Liquid error/).length
    assert_equal 2, error_count, "Should have exactly 2 error messages, got #{error_count}"
  end
end
