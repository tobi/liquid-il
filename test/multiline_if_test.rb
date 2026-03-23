# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

class MultilineIfTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def assert_renders(template, assigns = {}, msg = nil)
    og_result = Liquid::Template.parse(template).render(assigns)
    il_result = @ctx.render(template, assigns)
    assert_equal og_result, il_result,
      "#{msg || 'Output mismatch'}\n  Template: #{template.inspect}\n  Assigns: #{assigns.inspect}\n  OG Liquid: #{og_result.inspect}\n  LiquidIL: #{il_result.inspect}"
  end

  def test_multiline_if_with_or_and_mix
    # Reproduces the footer condition from the entity recording test
    template = <<~LIQUID
      {%- if a > 0
        or b
        or c
        and d == true
        or e
      -%}YES{%- endif -%}
    LIQUID

    assigns = { "a" => 0, "b" => false, "c" => true, "d" => true, "e" => false }
    assert_renders(template, assigns, "multiline if with or/and mix")
  end

  def test_simple_or_and_mix
    template = '{% if a or b and c %}YES{% endif %}'
    assigns = { "a" => false, "b" => true, "c" => true }
    assert_renders(template, assigns, "simple or/and mix")
  end

  def test_multiple_or_then_and
    template = '{% if a or b or c and d %}YES{% endif %}'
    assigns = { "a" => false, "b" => false, "c" => true, "d" => true }
    assert_renders(template, assigns, "multiple or then and")
  end

  def test_multiple_or_then_and_or
    template = '{% if a or b or c and d or e %}YES{% endif %}'
    assigns = { "a" => false, "b" => false, "c" => true, "d" => true, "e" => false }
    assert_renders(template, assigns, "multiple or then and then or")
  end

  def test_with_comparisons
    # Exact replica of the footer condition
    template = <<~LIQUID
      {%- assign has_social = true -%}
      {%- if blocks_size > 0
        or newsletter
        or show_social
        and has_social == true
        or follow_on_shop
      -%}INSIDE{%- endif -%}
    LIQUID

    assigns = {
      "blocks_size" => 0,
      "newsletter" => false,
      "show_social" => true,
      "follow_on_shop" => false,
    }
    assert_renders(template, assigns, "footer condition replica")
  end

  def test_or_and_with_property_lookups
    # Reproduces the exact footer condition with section.settings.* lookups
    template = '{% if a.size > 0 or b.settings.newsletter or b.settings.show_social and d == true or b.settings.follow %}YES{% endif %}'
    assigns = {
      "a" => [],
      "b" => { "settings" => { "newsletter" => false, "show_social" => true, "follow" => false } },
      "d" => true,
    }
    assert_renders(template, assigns, "or/and with property lookups")
  end

  def test_or_and_with_deep_property_and_comparison
    template = '{% if obj.a > 0 or obj.b or obj.c and val == true or obj.d %}YES{% endif %}'
    assigns = {
      "obj" => { "a" => 0, "b" => false, "c" => true, "d" => false },
      "val" => true,
    }
    assert_renders(template, assigns, "deep property with comparison in or/and chain")
  end
end
