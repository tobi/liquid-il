# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# === register_filter ===

module PureMoneyFilter
  def money(input, currency = "USD")
    "$#{"%.2f" % input.to_f} #{currency}"
  end

  def double(input)
    (input.to_f * 2).to_s
  end
end

module ImpureTagFilter
  def page_info(input)
    "#{input} (impure)"
  end
end

class RegisterFilterTest < Minitest::Test
  def test_pure_filter_basic
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$42.50 USD", ctx.render("{{ price | money }}", "price" => 42.5)
  end

  def test_pure_filter_with_args
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$99.00 EUR", ctx.render('{{ price | money: "EUR" }}', "price" => 99)
  end

  def test_pure_filter_chained
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$42.00 USD | upcase", ctx.render("{{ price | money | append: ' | upcase' }}", "price" => 42)
  end

  def test_impure_filter_basic
    ctx = LiquidIL::Context.new
    ctx.register_filter(ImpureTagFilter)
    assert_equal "hello (impure)", ctx.render("{{ name | page_info }}", "name" => "hello")
  end

  def test_filter_with_builtin
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureMoneyFilter, pure: true)
    # Custom filter chained with builtin
    assert_equal "$42.00 USD", ctx.render("{{ price | money | strip }}", "price" => 42)
  end

  def test_register_filter_requires_module
    ctx = LiquidIL::Context.new
    assert_raises(ArgumentError) { ctx.register_filter("not a module") }
  end

  def test_filter_overrides_unknown_filter_passthrough
    ctx = LiquidIL::Context.new
    # Without filter registered, unknown filter returns input
    assert_equal "hello", ctx.render("{{ name | money }}", "name" => "hello")
    # With filter registered
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$0.00 USD", ctx.render("{{ name | money }}", "name" => "hello")
  end

  def test_register_filter_invalidates_cache
    ctx = LiquidIL::Context.new
    # First parse/render without filter
    t1 = ctx.parse("{{ x | money }}")
    assert_equal "42", t1.render("x" => 42)

    # Register filter and re-parse
    ctx.register_filter(PureMoneyFilter, pure: true)
    t2 = ctx.parse("{{ x | money }}")
    assert_equal "$42.00 USD", t2.render("x" => 42)
  end

  def test_multiple_filters_from_same_module
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$42.00 USD", ctx.render("{{ x | money }}", "x" => 42)
    assert_equal "84.0", ctx.render("{{ x | double }}", "x" => 42)
  end
end

# === strict_filters ===

class StrictFiltersTest < Minitest::Test
  def test_strict_filters_raises_on_unknown
    ctx = LiquidIL::Context.new(strict_filters: true)
    t = ctx.parse("{{ x | nonexistent }}")
    assert_raises(LiquidIL::UndefinedFilter) { t.render!("x" => "hello") }
  end

  def test_strict_filters_allows_builtins
    ctx = LiquidIL::Context.new(strict_filters: true)
    assert_equal "HELLO", ctx.render("{{ x | upcase }}", "x" => "hello")
  end

  def test_strict_filters_allows_custom
    ctx = LiquidIL::Context.new(strict_filters: true)
    ctx.register_filter(PureMoneyFilter, pure: true)
    assert_equal "$42.00 USD", ctx.render("{{ x | money }}", "x" => 42)
  end

  def test_strict_filters_inline_error_with_render_errors
    ctx = LiquidIL::Context.new(strict_filters: true)
    t = ctx.parse("{{ x | nonexistent }}")
    result = t.render("x" => "hello")
    assert_match(/undefined filter nonexistent/, result)
  end

  def test_strict_filters_per_render_override
    ctx = LiquidIL::Context.new
    t = ctx.parse("{{ x | nonexistent }}")
    # Default: no error
    assert_equal "hello", t.render("x" => "hello")
    # Per-render strict: raises
    assert_raises(LiquidIL::UndefinedFilter) { t.render!({"x" => "hello"}, strict_filters: true) }
  end
end

# === strict_variables ===

class StrictVariablesTest < Minitest::Test
  def test_strict_variables_raises_on_undefined
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ name }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}) }
  end

  def test_strict_variables_allows_defined
    ctx = LiquidIL::Context.new(strict_variables: true)
    assert_equal "Hello World", ctx.render("Hello {{ name }}", "name" => "World")
  end

  def test_strict_variables_allows_nil_value
    ctx = LiquidIL::Context.new(strict_variables: true)
    # Explicitly set to nil is defined (should not raise)
    assert_equal "Hello ", ctx.render("Hello {{ name }}", "name" => nil)
  end

  def test_strict_variables_inline_error_with_render_errors
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ missing }}")
    result = t.render({})
    assert_match(/undefined variable missing/, result)
  end

  def test_strict_variables_per_render_override
    ctx = LiquidIL::Context.new
    t = ctx.parse("{{ missing }}")
    # Default: no error, returns ""
    assert_equal "", t.render({})
    # Per-render strict: raises
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}, strict_variables: true) }
  end

  def test_strict_variables_works_in_render_partials
    fs = SimpleFS.new("part" => "{{ missing }}")
    ctx = LiquidIL::Context.new(file_system: fs, strict_variables: true)
    t = ctx.parse("{% render 'part' %}")
    result = t.render({})
    assert_match(/undefined variable missing/, result)
  end
end

# === render! ===

class RenderBangTest < Minitest::Test
  def test_render_bang_raises_on_error
    # strict_errors + render! raises on undefined variables
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ missing }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}) }
  end

  def test_render_bang_returns_output_on_success
    t = LiquidIL::Template.parse("Hello {{ name }}")
    assert_equal "Hello World", t.render!("name" => "World")
  end

  def test_render_bang_accepts_options
    ctx = LiquidIL::Context.new
    t = ctx.parse("{{ name }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}, strict_variables: true) }
  end
end

# === Resource Limits ===

class ResourceLimitsTest < Minitest::Test
  def test_render_score_limit_stops_loops
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 10 })
    t = ctx.parse("{% for i in (1..100) %}x{% endfor %}")
    result = t.render({})
    assert_match(/Rendering limits exceeded/, result)
    # Should have rendered some x's before hitting limit
    assert result.include?("x"), "Should have some output before limit"
  end

  def test_render_score_limit_counts_nested_loops
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 20 })
    t = ctx.parse("{% for i in (1..10) %}{% for j in (1..10) %}x{% endfor %}{% endfor %}")
    result = t.render({})
    assert_match(/Rendering limits exceeded/, result)
  end

  def test_output_limit_stops_large_output
    ctx = LiquidIL::Context.new(resource_limits: { output_limit: 20 })
    t = ctx.parse("{% for i in (1..100) %}hello{% endfor %}")
    result = t.render({})
    assert_match(/Memory limits exceeded/, result)
  end

  def test_no_limits_has_zero_overhead
    ctx = LiquidIL::Context.new
    t = ctx.parse("{% for i in (1..5) %}x{% endfor %}")
    # Verify no resource limit code in compiled output
    refute t.compiled_source.include?("increment_render_score"), "Should not emit limit code when no limits configured"
    refute t.compiled_source.include?("check_output_limit"), "Should not emit limit code when no limits configured"
    assert_equal "xxxxx", t.render({})
  end

  def test_limits_present_emits_check_code
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 1000 })
    t = ctx.parse("{% for i in (1..5) %}x{% endfor %}")
    assert t.compiled_source.include?("increment_render_score"), "Should emit limit code when limits configured"
  end

  def test_render_score_limit_raises_in_strict_mode
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 5 })
    t = ctx.parse("{% for i in (1..100) %}x{% endfor %}")
    assert_raises(LiquidIL::ResourceLimitError) { t.render!({}) }
  end

  def test_output_limit_with_partial
    fs = SimpleFS.new("loop" => "{% for i in (1..100) %}x{% endfor %}")
    ctx = LiquidIL::Context.new(file_system: fs, resource_limits: { output_limit: 30 })
    t = ctx.parse("start{% render 'loop' %}end")
    result = t.render({})
    assert_match(/Memory limits exceeded/, result)
    assert result.start_with?("start"), "Should have output before partial"
  end

  def test_tablerow_counts_render_score
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 5 })
    t = ctx.parse("{% tablerow i in (1..100) cols:3 %}{{ i }}{% endtablerow %}")
    result = t.render({})
    assert_match(/Rendering limits exceeded/, result)
  end
end

# === User-facing Registers ===

class RegistersTest < Minitest::Test
  def test_context_registers_accessible
    ctx = LiquidIL::Context.new(registers: { page_type: "product" })
    assert_equal({ page_type: "product" }, ctx.registers)
  end

  def test_render_time_registers_merge
    ctx = LiquidIL::Context.new(registers: { a: 1 })
    t = ctx.parse("hello")
    # This just verifies no error — registers flow through to scope
    assert_equal "hello", t.render({}, registers: { b: 2 })
  end

  def test_render_time_registers_override
    ctx = LiquidIL::Context.new(registers: { a: 1 })
    t = ctx.parse("hello")
    assert_equal "hello", t.render({}, registers: { a: 2 })
  end
end

# === Helper ===

class SimpleFS
  def initialize(files)
    @files = {}
    files.each { |k, v| @files[k] = v }
  end

  def read_template_file(name)
    @files[name]
  end
end
