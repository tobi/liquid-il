# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

# Tests for include/render with bracket expressions containing dots in arguments,
# and for OR expressions with blank/empty comparisons.
class IncludeBracketDotTest < Minitest::Test
  # Minimal file system shared by OG Liquid and LiquidIL
  class SimpleFS
    def initialize(templates)
      @templates = templates
    end

    def read_template_file(name)
      @templates[name] || raise("Template not found: #{name}")
    end
  end

  def assert_renders(template, assigns = {}, msg = nil, fs: nil)
    parse_opts = {}
    if fs
      og_env = Liquid::Environment.build { |e| e.file_system = fs }
      parse_opts[:environment] = og_env
    end
    og_result = Liquid::Template.parse(template, **parse_opts).render(assigns)

    il_ctx = LiquidIL::Context.new(file_system: fs)
    il_result = il_ctx.render(template, assigns)

    assert_equal og_result, il_result,
      "#{msg || 'Output mismatch'}\n  Template: #{template.inspect}\n  OG: #{og_result.inspect}\n  IL: #{il_result.inspect}"
  end

  def test_include_with_bracket_dot_expression_in_arg
    # Simulates: include 'navlist', menu_list: linklists[block.settings.menu].links
    fs = SimpleFS.new({
      "snippet" => "{% for item in items %}[{{ item }}]{% endfor %}",
    })

    template = "{% include 'snippet', items: data[config.key].values %}"
    assigns = {
      "data" => {
        "my_menu" => { "values" => ["a", "b", "c"] },
      },
      "config" => { "key" => "my_menu" },
    }

    assert_renders(template, assigns, "include arg with bracket dot expression", fs: fs)
  end

  def test_include_with_simple_bracket_expression_in_arg
    # Simpler version: include 'snippet', items: data[key].values
    fs = SimpleFS.new({
      "snippet" => "{% for item in items %}[{{ item }}]{% endfor %}",
    })

    template = "{% include 'snippet', items: data[key].values %}"
    assigns = {
      "data" => {
        "my_menu" => { "values" => ["x", "y"] },
      },
      "key" => "my_menu",
    }

    assert_renders(template, assigns, "include arg with simple bracket expression", fs: fs)
  end

  # Regression: OR with blank comparison was mis-compiled.
  # `a > b or x == blank` was becoming `(a > b or x) == blank`.
  def test_or_with_blank_comparison
    template = <<~LIQUID.chomp
      {% assign a = 2 %}{% assign b = 1 %}{% if a > b or x == blank %}YES{% else %}NO{% endif %}
    LIQUID
    assert_renders(template, {}, "or with blank comparison")
  end

  def test_or_with_empty_comparison
    template = <<~LIQUID.chomp
      {% assign a = 2 %}{% assign b = 1 %}{% if a > b or x == empty %}YES{% else %}NO{% endif %}
    LIQUID
    assert_renders(template, {}, "or with empty comparison")
  end

  def test_or_with_variable_gt_and_blank
    template = <<~LIQUID.chomp
      {% assign d = 2 %}{% if d > 1 or items == blank %}YES{% else %}NO{% endif %}
    LIQUID
    assert_renders(template, {}, "variable gt with or blank")
  end
end
