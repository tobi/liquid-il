# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class RubyCompilerTest < Minitest::Test
  def compile_ruby(source, **assigns)
    LiquidIL::Compiler::Ruby.compile(source).render(assigns)
  end

  def test_for_loop_compiles_to_each_with_index
    template = LiquidIL::Compiler::Ruby.compile("{% for i in items %}{{ i }}{% endfor %}")
    source = template.compiled_source

    assert source, "Ruby compiler should emit Ruby source"
    assert_match(/each_iter\(/, source)
  end

  def test_for_loop_renders
    assert_equal "123", compile_ruby("{% for i in items %}{{ i }}{% endfor %}", items: [1, 2, 3])
  end
end
