# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Case/when must conform to reference Liquid semantics: the parser creates ONE
# condition block per when-VALUE (so `{% when 'a', 'a' %}` is two blocks), and
# at render EVERY matching block renders its body (no first-match break). Two
# separate `{% when 'a' %}` clauses both fire; duplicate values render the body
# once per occurrence; else renders only when no when matched (and does not
# flip that flag). See Parser#parse_when_clause_with_flag.
class CaseWhenSemanticsTest < Minitest::Test
  def render(src, assigns = {})
    LiquidIL::Template.parse(src).render(assigns)
  end

  def test_duplicate_values_in_one_when_render_body_per_value
    assert_equal "MM", render("{% case 'a' %}{% when 'a','a' %}M{% endcase %}")
  end

  def test_two_separate_when_clauses_with_same_value_both_fire
    assert_equal "12", render("{% case 'a' %}{% when 'a' %}1{% when 'a' %}2{% endcase %}")
  end

  def test_else_fires_when_no_when_matches
    assert_equal "E", render("{% case 'a' %}{% when 'b' %}n{% else %}E{% endcase %}")
  end

  def test_else_suppressed_when_a_when_matched
    assert_equal "m", render("{% case 'a' %}{% when 'a' %}m{% else %}E{% endcase %}")
  end

  def test_duplicate_nil_values_advance_cycle_state_across_body_renders
    # Recorded reference behavior: two matching blocks share the body, so the
    # cycle inside it steps twice.
    assert_equal "0.00.0", render("{% case nil %}{% when nil, nil %}{% cycle 0.0 %}{% endcase %}")
  end

  def test_triple_duplicate_value_runs_side_effect_three_times
    assert_equal "0123",
      render("{% case 'a' %}{% when 'a','a','a' %}{% increment c %}{% endcase %}{{c}}")
  end

  def test_multi_value_distinct_matches_once
    assert_equal "X", render("{% case 'b' %}{% when 'a','b' %}X{% else %}E{% endcase %}")
  end

  def test_or_separator_between_when_values
    assert_equal "YY", render("{% case 1 %}{% when 1 or 1 %}Y{% endcase %}")
  end

  def test_duplicated_body_with_nested_loop_relinks
    # Duplicated bodies get fresh labels so the nested for-loop stays linkable.
    assert_equal "1212",
      render("{% case 'a' %}{% when 'a','a' %}{% for i in (1..2) %}{{i}}{% endfor %}{% endcase %}")
  end

  def test_no_matching_when_and_no_else_renders_nothing
    assert_equal "", render("{% case 'z' %}{% when 'a' %}A{% endcase %}")
  end

  def test_case_subject_evaluated_once_into_temp
    # Subject is a counter drop read once; two whens must not re-read it.
    assert_equal "hit", render("{% case x %}{% when 1 %}hit{% when 2 %}miss{% endcase %}", { "x" => 1 })
  end
end
