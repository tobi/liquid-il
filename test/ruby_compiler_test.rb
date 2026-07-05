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

  # ── Statement-run dedup (StatementDedup) ────────────────────────────────

  # (a) A repeated eligible run compiles to exactly ONE sequence lambda and one
  # CALL_SEQ site per occurrence.
  def test_statement_dedup_one_definition_n_calls
    # The money "output core": ${{ d }}.{% if c < 10 %}0{% endif %}{{ c }},
    # here reading distinct render inputs so each block is a fresh occurrence.
    src = (1..4).map { |i| "P#{i}{{ a#{i} }}.{% if b#{i} < 10 %}0{% endif %}{{ b#{i} }}Q#{i}" }.join
    t = LiquidIL::Compiler::Ruby.compile(src)
    code = t.compiled_source
    assert_equal 1, code.scan(/_sq0__ = ->/).length, "expected exactly one sequence lambda"
    assert_equal 1, code.scan(/_sq\d+__ = ->/).length, "expected no other sequences"
    assert_equal 4, code.scan(/_sq0__\.call/).length, "expected one call per occurrence"
    assert_equal "P15.03Q1P27.12Q2P31.09Q3P42.40Q4",
      t.render("a1" => 5, "b1" => 3, "a2" => 7, "b2" => 12, "a3" => 1, "b3" => 9, "a4" => 2, "b4" => 40)
  end

  # (b) A repeated run containing {% break %} is NEVER deduped: PUSH_INTERRUPT is
  # off the allowlist, and break/continue inside a lambda body would change
  # meaning (return from the lambda, not the enclosing loop driver).
  def test_statement_dedup_refuses_break_block
    src = (1..3).map do |i|
      "{% for z in zs %}{{ a#{i} }}.{% if b#{i} < 10 %}0{% endif %}{{ b#{i} }}{% break %}{% endfor %}"
    end.join
    t = LiquidIL::Compiler::Ruby.compile(src)
    refute_match(/_sq\d+__ = ->/, t.compiled_source, "break-bearing blocks must not dedup")
    assert_equal "5.03", t.render("a1" => 5, "b1" => 3, "zs" => [1], "a2" => 5, "b2" => 3, "a3" => 5, "b3" => 3)[0, 4]
  end

  # (c) Repeated blocks that differ only in their assign targets render exactly
  # like the un-deduped (optimize:false) compilation. Exercises the dual local
  # mechanism (target assigned AND read back inside one run).
  def test_statement_dedup_matches_unoptimized_output
    src = (1..4).map { |i| "{% assign m#{i} = k#{i} | plus: 1 %}[{{ m#{i} }}/{{ m#{i} }}]" }.join
    deduped = LiquidIL::Compiler::Ruby.compile(src)
    assert_match(/_sq0__ = ->/, deduped.compiled_source, "expected the run to dedup")
    assert_match(/_sqv1__/, deduped.compiled_source, "expected a dual local for the read-back target")
    assigns = { "k1" => 10, "k2" => 20, "k3" => 30, "k4" => 40 }
    unoptimized = LiquidIL::Compiler::Ruby.compile(src, optimize: false)
    assert_equal unoptimized.render(assigns), deduped.render(assigns)
    assert_equal "[11/11][21/21][31/31][41/41]", deduped.render(assigns)
  end
end
