# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Reference Liquid (BlockBody.rescue_render_node) appends a rendered node's
# error text UNLESS the node is blank. LiquidIL reproduces that suppression
# ONLY for templates parsed with error_mode :lax — a deliberate, documented
# Suppression applies in :lax and :strict (historical reference behavior);
# :strict2 is the new contract where blank bodies surface. render! (which
# renders with render_errors=false) must keep raising in every mode, blank or
# not. See Parser#mark_blank_error_suppression and the codegen suppress paths.
class BlankErrorSuppressionTest < Minitest::Test
  def lax
    @lax ||= LiquidIL::Context.new(error_mode: :lax)
  end

  def strict
    @strict ||= LiquidIL::Context.new(error_mode: :strict)
  end

  # ── lax: blank constructs swallow the error text ──────────────────

  def test_lax_blank_if_body_suppresses_error_text
    assert_equal "", lax.parse('{% if 5 > "x" %}{% endif %}').render({})
  end

  def test_lax_nonblank_if_body_still_shows_error_text
    result = lax.parse('{% if 5 > "x" %}X{% endif %}').render({})
    assert_includes result, "Liquid error"
    assert_includes result, "comparison of Integer with String failed"
  end

  def test_lax_if_body_of_only_assign_is_blank_and_suppresses
    assert_equal "", lax.parse('{% if 5 > "x" %}{% assign a = 1 %}{% endif %}').render({})
  end

  def test_lax_unless_whitespace_body_is_blank_and_suppresses
    assert_equal "", lax.parse('{% unless 5 > "x" %} {% endunless %}').render({})
  end

  def test_lax_blank_elsif_condition_suppresses
    assert_equal "", lax.parse('{% if false %}{% elsif 5 > "x" %}{% endif %}').render({})
  end

  def test_lax_nonblank_elsif_condition_shows_error
    result = lax.parse('{% if false %}{% elsif 5 > "x" %}Y{% endif %}').render({})
    assert_includes result, "Liquid error"
  end

  # ── strict: historical suppression preserved; strict2 surfaces ────

  def strict2
    @strict2 ||= LiquidIL::Context.new(error_mode: :strict2)
  end

  def test_strict_blank_if_body_suppresses_error_text
    assert_equal "", strict.parse('{% if 5 > "x" %}{% endif %}').render({})
  end

  def test_strict2_blank_if_body_shows_error_text
    result = strict2.parse('{% if 5 > "x" %}{% endif %}').render({})
    assert_includes result, "Liquid error"
    assert_includes result, "comparison of Integer with String failed"
  end

  # ── render! raises in every mode, blank or not ────────────────────

  def test_render_bang_raises_for_blank_if_in_lax
    assert_raises(LiquidIL::RuntimeError) do
      lax.parse('{% if 5 > "x" %}{% endif %}').render!({})
    end
  end

  def test_render_bang_raises_for_nonblank_if_in_lax
    assert_raises(LiquidIL::RuntimeError) do
      lax.parse('{% if 5 > "x" %}X{% endif %}').render!({})
    end
  end

  def test_render_bang_raises_for_blank_if_in_strict
    assert_raises(LiquidIL::RuntimeError) do
      strict.parse('{% if 5 > "x" %}{% endif %}').render!({})
    end
  end

  # ── blankness must not skip the body's side effects ───────────────

  def test_lax_true_condition_blank_body_still_runs_assign
    # The construct is "blank" (assign-only body) for suppression purposes, but
    # a non-erroring true condition must still execute the assign.
    assert_equal "1", lax.parse('{% if x %}{% assign a = 1 %}{% endif %}{{ a }}').render({ "x" => true })
  end

  def test_lax_constant_true_blank_body_still_runs_assign
    assert_equal "1", lax.parse('{% if true %}{% assign a = 1 %}{% endif %}{{ a }}').render({})
  end

  # ── for/tablerow offset-limit errors ──────────────────────────────

  def test_lax_blank_for_loop_offset_error_suppressed
    assert_equal "", lax.parse('{% for i in (1..3) offset: "x" %}{% endfor %}').render({})
  end

  def test_lax_nonblank_for_loop_offset_error_shown
    result = lax.parse('{% for i in (1..3) offset: "x" %}Q{% endfor %}').render({})
    assert_includes result, "Liquid error"
    assert_includes result, "invalid integer"
  end

  def test_strict_blank_for_loop_offset_error_suppressed
    assert_equal "", strict.parse('{% for i in (1..3) offset: "x" %}{% endfor %}').render({})
  end

  def test_strict2_blank_for_loop_offset_error_shown
    result = strict2.parse('{% for i in (1..3) offset: "x" %}{% endfor %}').render({})
    assert_includes result, "Liquid error"
    assert_includes result, "invalid integer"
  end

  def test_render_bang_raises_for_blank_for_loop_offset_in_lax
    assert_raises(LiquidIL::RuntimeError) do
      lax.parse('{% for i in (1..3) offset: "x" %}{% endfor %}').render!({})
    end
  end
end
