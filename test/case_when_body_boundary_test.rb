# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

# Regression test for case/when body boundary bug in ruby_compiler.
#
# The bug: generate_case_when_or() parsed the when body until it found
# LOAD_TEMP (next when clause) or HALT. For the LAST when clause there's
# no following LOAD_TEMP, so it consumed all instructions after endcase
# (and even after endfor), nesting them inside the last when's if-block.
#
# Symptom: content after {% endcase %} only rendered when the last when
# clause matched. Inside a for loop, this meant post-case content was
# missing for all iterations except the one matching the last when value.
class CaseWhenBodyBoundaryTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def assert_parity(template, assigns = {}, msg = nil)
    og_result = Liquid::Template.parse(template).render(assigns)
    il_result = @ctx.render(template, assigns)
    assert_equal og_result, il_result,
      "#{msg || 'Output mismatch'}\n  Template: #{template.inspect}\n  Assigns:  #{assigns.inspect}\n  OG Liquid: #{og_result.inspect}\n  LiquidIL:  #{il_result.inspect}"
  end

  # Core regression: content after endcase inside a for loop must render every iteration
  def test_content_after_endcase_renders_every_iteration
    assert_parity(
      "{%- for i in (1..3) -%}[{{i}}]{%- case i -%}{%- when 1 -%}A{%- when 2 -%}B{%- when 3 -%}C{%- endcase -%}+{%- endfor -%}",
      {},
      "Content after endcase must render on every for iteration, not just the last when match"
    )
  end

  # Same bug but with string values
  def test_content_after_endcase_with_string_values
    assert_parity(
      "{%- for x in items -%}{%- case x -%}{%- when 'a' -%}A{%- when 'b' -%}B{%- when 'c' -%}C{%- endcase -%}|{%- endfor -%}done",
      { "items" => %w[a b c a] },
      "Post-endcase content with string when values"
    )
  end

  # Content after endcase outside a for loop (simpler case)
  def test_content_after_endcase_standalone
    assert_parity(
      "{%- case x -%}{%- when 1 -%}A{%- when 2 -%}B{%- endcase -%}AFTER",
      { "x" => 1 },
      "Content after endcase should render when first when matches (not last)"
    )
  end

  # Content after endfor must not be swallowed into last when
  def test_content_after_endfor_not_swallowed
    assert_parity(
      "{%- for i in (1..2) -%}{%- case i -%}{%- when 1 -%}X{%- when 2 -%}Y{%- endcase -%}{%- endfor -%}TAIL",
      {},
      "Content after endfor must not be nested inside last when clause"
    )
  end

  # Multiple case statements in same for loop
  def test_multiple_case_statements_in_for
    assert_parity(
      "{%- for i in (1..2) -%}{%- case i -%}{%- when 1 -%}A{%- when 2 -%}B{%- endcase -%},{%- case i -%}{%- when 1 -%}X{%- when 2 -%}Y{%- endcase -%}|{%- endfor -%}",
      {},
      "Multiple case statements in the same for body"
    )
  end

  # Case with else clause (else uses flag-based detection via LOAD_TEMP)
  def test_case_with_else_in_for
    assert_parity(
      "{%- for i in (1..3) -%}{%- case i -%}{%- when 1 -%}A{%- when 2 -%}B{%- else -%}?{%- endcase -%}+{%- endfor -%}",
      {},
      "Case with else clause inside for loop"
    )
  end

  # Nested for loops with case
  def test_nested_for_with_case
    assert_parity(
      "{%- for i in (1..2) -%}{%- for j in (1..2) -%}{%- case j -%}{%- when 1 -%}a{%- when 2 -%}b{%- endcase -%}.{%- endfor -%}|{%- endfor -%}",
      {},
      "Nested for loops with case in inner loop"
    )
  end

  # Case with or-style when (when 1, 2)
  def test_case_with_or_when_in_for
    assert_parity(
      "{%- for i in (1..4) -%}{%- case i -%}{%- when 1, 2 -%}AB{%- when 3 -%}C{%- when 4 -%}D{%- endcase -%}+{%- endfor -%}",
      {},
      "Case with comma-separated when values inside for loop"
    )
  end
end
