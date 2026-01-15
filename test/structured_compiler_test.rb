# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class StructuredCompilerTest < Minitest::Test
  def compile_structured(source, **assigns)
    LiquidIL::Compiler::Structured.compile(source).render(assigns)
  end

  def test_for_loop_compiles_to_each_with_index
    template = LiquidIL::Compiler::Structured.compile("{% for i in items %}{{ i }}{% endfor %}")
    source = template.compiled_source

    refute template.uses_vm, "Simple for loop should compile to structured Ruby"
    assert source, "Structured compiler should emit Ruby source"
    assert_match(/\.each_with_index do \|__item_0__, __idx_0__\|/, source)
  end

  def test_for_loop_renders
    assert_equal "123", compile_structured("{% for i in items %}{{ i }}{% endfor %}", items: [1, 2, 3])
  end
end
