# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class RubyCompilerTest < Minitest::Test
  def compile_ruby(source, **assigns)
    LiquidIL::Compiler::Ruby.compile(source).render(assigns)
  end

  def test_simple_for_loop_compiles_to_ei_fast_path
    template = LiquidIL::Compiler::Ruby.compile("{% for i in items %}{{ i }}{% endfor %}")
    source = template.compiled_source

    assert source, "Ruby compiler should emit Ruby source"
    # Simple loops emit one _H.ei block (driver in the jitted runtime,
    # ~190B of ISeq saved per loop) instead of inline while machinery.
    assert_match(/_H\.ei\(_S\.lookup\("items"\)\) do \|_i0__\|/, source)
    refute_match(/while __i0__/, source)
  end

  def test_for_loop_renders
    assert_equal "123", compile_ruby("{% for i in items %}{{ i }}{% endfor %}", items: [1, 2, 3])
  end

  # Effects-frame path selection: the sync decision comes from recorded
  # scope effects, not from substring-matching the generated body.
  class StubFS
    def initialize(templates) = @templates = templates
    def read_template_file(name, _context = nil) = @templates[name.to_s]
  end

  def compile_with_partials(source, partials)
    LiquidIL::Context.new(file_system: StubFS.new(partials)).parse(source)
  end

  def test_isolated_render_in_loop_stays_on_fast_path
    t = compile_with_partials("{% for p in ps %}{% render 'card', product: p %}{% endfor %}",
                              "card" => "[{{ product.name }}]")
    # render cannot see caller locals; its args resolve via the loop alias —
    # no scope sync needed.
    assert_match(/_H\.ei\(/, t.compiled_source)
    refute_match(/_H\.eifs\(/, t.compiled_source)
    assert_equal "[a][b]", t.render!("ps" => [{ "name" => "a" }, { "name" => "b" }])
  end

  def test_include_in_loop_syncs_scope
    t = compile_with_partials("{% for p in ps %}{% include 'inc' %}{% endfor %}",
                              "inc" => "[{{ p.name }}]")
    # include reads the caller scope at render time — the item must be
    # published per iteration.
    assert_match(/_H\.eifs\(/, t.compiled_source)
    assert_equal "[a][b]", t.render!("ps" => [{ "name" => "a" }, { "name" => "b" }])
  end

  def test_nested_loop_without_parentloop_passes_nil_parent
    t = LiquidIL::Compiler::Ruby.compile(
      "{% for a in xs %}{% for b in ys %}{{ forloop.index }}{% endfor %}{% endfor %}"
    )
    # The parent-forloop argument is only observable through
    # forloop.parentloop; without it the inner drop carries nil and the
    # outer loop needs no drop at all.
    assert_match(/_H\.eif\(_S\.lookup\("ys"\), "b-ys", nil\)/, t.compiled_source)
    assert_equal "1212", t.render!("xs" => [1, 2], "ys" => [3, 4])
  end

  def test_nested_parentloop_uses_outer_drop_local
    t = LiquidIL::Compiler::Ruby.compile(
      "{% for a in xs %}{% for b in ys %}{{ forloop.parentloop.index }}{% endfor %}{% endfor %}"
    )
    # parentloop access binds the inner drop to the outer drop's local
    # directly — no scope read, no sync on the outer loop.
    assert_match(/_H\.eif\(_S\.lookup\("ys"\), "b-ys", _fl0__\)/, t.compiled_source)
    refute_match(/_H\.eifs\(/, t.compiled_source)
    assert_equal "1122", t.render!("xs" => [1, 2], "ys" => [3, 4])
  end
end
