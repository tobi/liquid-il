# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class StructuredCompilerTest < Minitest::Test
  def compile_structured(source, **assigns)
    LiquidIL::Compiler::Structured.compile(source).render(assigns)
  end

  def test_for_loop_compiles_to_each_do
    template = LiquidIL::Compiler::Structured.compile("{% for i in items %}{{ i }}{% endfor %}")
    source = template.compiled_source

    refute template.uses_vm, "Simple for loop should compile to structured Ruby"
    assert source, "Structured compiler should emit Ruby source"
    assert_match(/\.each do \|__item_0__\|/, source)
    refute_match(/each_with_index/, source, "Structured compiler should use each + manual index for YJIT-friendly loop")
    assert_match(/__idx_0__ = 0/, source)
    assert_match(/__idx_0__ \+= 1/, source)
  end

  def test_for_loop_renders
    assert_equal "123", compile_structured("{% for i in items %}{{ i }}{% endfor %}", items: [1, 2, 3])
  end
end
