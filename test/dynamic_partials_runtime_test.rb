# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class DynamicPartialsRuntimeTest < Minitest::Test
  class TrackingFS
    attr_reader :reads, :contexts

    def initialize(templates)
      @templates = templates
      @reads = Hash.new(0)
      @contexts = Hash.new { |h, k| h[k] = [] }
    end

    def read_template_file(name, context = nil)
      key = name.to_s
      @reads[key] += 1
      @contexts[key] << context
      @templates[key]
    end
  end

  def test_dynamic_include_is_not_loaded_at_parse_time
    fs = TrackingFS.new("card" => "CARD")
    ctx = LiquidIL::Context.new(file_system: fs)

    template = ctx.parse("{% include tpl %}")
    assert_equal({}, fs.reads)

    assert_equal "CARD", template.render("tpl" => "card")
    assert_equal 1, fs.reads["card"]
  end

  def test_dynamic_include_uses_template_name_from_assigns_each_render
    fs = TrackingFS.new("a" => "A", "b" => "B")
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% include tpl %}")

    assert_equal "A", template.render("tpl" => "a")
    assert_equal "B", template.render("tpl" => "b")
    assert_equal 1, fs.reads["a"]
    assert_equal 1, fs.reads["b"]
  end

  def test_dynamic_include_runs_in_caller_scope
    fs = TrackingFS.new("card" => "hello {{ name }}")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl %}", "tpl" => "card", "name" => "world")
    assert_equal "hello world", out
  end

  def test_dynamic_include_with_alias_and_value
    fs = TrackingFS.new("product_card" => "[{{ item.title }}]")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render(
      "{% include tpl with selected as item %}",
      "tpl" => "product_card",
      "selected" => { "title" => "Hat" }
    )
    assert_equal "[Hat]", out
  end

  def test_dynamic_include_for_clause_renders_each_element
    fs = TrackingFS.new("item" => "({{ item }})")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl for items %}", "tpl" => "item", "items" => [1, 2, 3])
    assert_equal "(1)(2)(3)", out
  end

  def test_nested_dynamic_include_compiles_and_executes_at_runtime
    fs = TrackingFS.new(
      "outer" => "[OUT:{% include inner_tpl %}]",
      "inner" => "IN={{ value }}"
    )
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render(
      "{% include tpl %}",
      "tpl" => "outer",
      "inner_tpl" => "inner",
      "value" => "ok"
    )

    assert_equal "[OUT:IN=ok]", out
    assert_equal 1, fs.reads["outer"]
    assert_equal 1, fs.reads["inner"]
  end

  def test_dynamic_include_missing_partial_reports_inline_error
    fs = TrackingFS.new({})
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl %}", "tpl" => "missing")
    assert_includes out, "Liquid error (line 1): Could not find partial 'missing'"
  end

  def test_dynamic_include_illegal_name_reports_argument_error
    fs = TrackingFS.new("x" => "X")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl %}", "tpl" => 123)
    assert_includes out, "Argument error in tag 'include' - Illegal template name"
  end

  def test_dynamic_include_syntax_error_reports_partial_name_and_line
    fs = TrackingFS.new("broken" => "{% if %}")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl %}", "tpl" => "broken")
    assert_includes out, "Liquid syntax error (broken line 1):"
  end

  def test_file_system_receives_runtime_scope_context
    fs = TrackingFS.new("card" => "OK")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% include tpl %}", "tpl" => "card")
    assert_equal "OK", out
    assert_equal 1, fs.contexts["card"].length
    assert_instance_of LiquidIL::Scope, fs.contexts["card"].first
  end
end
