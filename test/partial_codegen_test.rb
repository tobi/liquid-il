# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Regression tests for partial codegen bugs:
# 1. Double @pc increment swallowed the statement following a top-level
#    {% render %} / {% include %}.
# 2. A partial inlined at one call site had its lambda body skipped even when
#    another call site (with/for/include) still emitted a lambda call → nil.call.
# 3. A @@partial_cache hit never compiled the cached partial's nested partials,
#    so the second template compiled in a process raised
#    "undefined local variable __partial_x__".
class PartialCodegenTest < Minitest::Test
  class StubFS
    def initialize(templates)
      @templates = templates
    end

    def read_template_file(name, _context = nil)
      @templates[name.to_s]
    end
  end

  def render(template, assigns = {}, partials: {})
    ctx = LiquidIL::Context.new(file_system: StubFS.new(partials))
    ctx.parse(template).render(assigns)
  end

  def test_statement_after_top_level_render_is_not_swallowed
    assert_equal "AXB", render("A{% render 'x' %}B", partials: { "x" => "X" })
  end

  def test_statement_after_top_level_include_is_not_swallowed
    assert_equal "AXB", render("A{% include 'x' %}B", partials: { "x" => "X" })
  end

  def test_output_after_top_level_render_is_not_swallowed
    assert_equal "X-hi", render("{% render 'x' %}-{{ v }}", { "v" => "hi" }, partials: { "x" => "X" })
  end

  def test_mixed_inline_and_with_call_sites_share_one_partial
    out = render(
      "{% render 'item' %}|{% render 'item' with v as item %}",
      { "v" => "hi" },
      partials: { "item" => "[{{ item }}]" }
    )
    assert_equal "[]|[hi]", out
  end

  def test_mixed_inline_and_for_call_sites_share_one_partial
    out = render(
      "{% render 'item' %}|{% render 'item' for list as item %}",
      { "list" => %w[a b] },
      partials: { "item" => "[{{ item }}]" }
    )
    assert_equal "[]|[a][b]", out
  end

  def test_mixed_render_and_include_call_sites_share_one_partial
    out = render(
      "{% render 'item' %}|{% include 'item' %}",
      { "item" => "top" },
      partials: { "item" => "[{{ item }}]" }
    )
    assert_equal "[]|[top]", out
  end

  def test_partial_cache_hit_compiles_nested_partials
    partials = { "outer" => "<{% render 'inner' with v as item %}>", "inner" => "[{{ item }}]" }

    # First parse warms the class-level @@partial_cache for 'outer'.
    first = render("{% render 'outer', v: v %}", { "v" => "hi" }, partials: partials)
    assert_equal "<[hi]>", first

    # Second parse hits the cache; nested 'inner' must still be compiled.
    second = render("{% render 'outer', v: v %}", { "v" => "hi" }, partials: partials)
    assert_equal "<[hi]>", second
  end

  def test_render_does_not_see_top_level_assigns
    out = render("{% render 'item' %}", { "item" => "top" }, partials: { "item" => "[{{ item }}]" })
    assert_equal "[]", out
  end

  def test_cycle_inside_for_loop
    assert_equal "abab", render("{% for i in (1..4) %}{% cycle 'a','b' %}{% endfor %}")
  end

  # Partial-body rewrites are string-level gsubs over generated code; they
  # must skip string literals or raw text containing "_S" corrupts
  # (PRICE_START became PRICE__partial_scope__TART).
  def test_partial_raw_text_containing_scope_var_name_is_not_rewritten
    partials = { "chunk" => "PRICE_START {{ x }} _S.lookup OK_END" }
    assert_equal "PRICE_START 42 _S.lookup OK_END",
                 render("{% render 'chunk', x: 42 %}", partials: partials)
    assert_equal "PRICE_START 7 _S.lookup OK_END",
                 render("{% include 'chunk' %}", { "x" => 7 }, partials: partials)
  end

  # Lexer positions are byte offsets — multibyte characters before markup
  # must not shift tag detection (String#byteindex, not String#index).
  def test_multibyte_text_before_markup
    assert_equal "⭐V", render("⭐{{ x }}", { "x" => "V" })
    assert_equal "✅⚠️y", render("✅⚠️{% if x %}y{% endif %}", { "x" => true })
    assert_equal "日本語 V テスト", render("日本語 {{ x }} テスト", { "x" => "V" })
  end

  # A partial with its own for loop, inlined inside a caller's for loop,
  # must not clobber the caller's loop locals (unique loop-naming base).
  def test_inlined_partial_loop_does_not_clobber_caller_loop
    partials = {
      "row" => "<r>{% for p in item.props %}{{ p }}{% endfor %}</r>"
    }
    assigns = { "items" => [
      { "props" => %w[a b] }, { "props" => %w[c] }, { "props" => %w[d e f] }
    ] }
    out = render(
      "{% for item in items %}{% render 'row', item: item %}{% endfor %}",
      assigns, partials: partials
    )
    assert_equal "<r>ab</r><r>c</r><r>def</r>", out
  end
end
