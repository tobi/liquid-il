# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# ════════════════════════════════════════════════════════════
# HELPERS
# ════════════════════════════════════════════════════════════

class SimpleFS
  def initialize(files)
    @files = {}
    files.each { |k, v| @files[k] = v }
  end

  def read_template_file(name)
    @files[name]
  end
end

# ════════════════════════════════════════════════════════════
# 1. LiquidIL MODULE-LEVEL API
# ════════════════════════════════════════════════════════════

class LiquidILModuleAPITest < Minitest::Test
  def test_parse_returns_template
    t = LiquidIL.parse("hello")
    assert_instance_of LiquidIL::Template, t
  end

  def test_parse_with_assigns
    t = LiquidIL.parse("{{ x }}")
    assert_equal "42", t.render("x" => 42)
  end

  def test_render_one_shot
    assert_equal "hello world", LiquidIL.render("hello {{ x }}", "x" => "world")
  end

  def test_render_one_shot_with_options
    result = LiquidIL.render("{{ x }}", { "x" => 42 })
    assert_equal "42", result
  end
end

# ════════════════════════════════════════════════════════════
# 2. CONTEXT — CREATION AND CONFIGURATION
# ════════════════════════════════════════════════════════════

class ContextCreationTest < Minitest::Test
  def test_default_context
    ctx = LiquidIL::Context.new
    assert_nil ctx.file_system
    assert_equal false, ctx.strict_errors
    assert_equal({}, ctx.registers)
    assert_equal false, ctx.strict_variables
    assert_equal false, ctx.strict_filters
    assert_nil ctx.resource_limits
    assert_equal :lax, ctx.error_mode
    assert_equal({}, ctx.custom_filters)
  end

  def test_context_with_all_options
    fs = SimpleFS.new({})
    ctx = LiquidIL::Context.new(
      file_system: fs,
      strict_errors: true,
      registers: { page: "home" },
      strict_variables: true,
      strict_filters: true,
      resource_limits: { output_limit: 1000 },
      error_mode: :strict
    )
    assert_equal fs, ctx.file_system
    assert_equal true, ctx.strict_errors
    assert_equal({ page: "home" }, ctx.registers)
    assert_equal true, ctx.strict_variables
    assert_equal true, ctx.strict_filters
    assert_equal({ output_limit: 1000 }, ctx.resource_limits)
    assert_equal :strict, ctx.error_mode
  end

  def test_context_parse_returns_template
    ctx = LiquidIL::Context.new
    t = ctx.parse("hello {{ x }}")
    assert_instance_of LiquidIL::Template, t
  end

  def test_context_render_one_shot
    ctx = LiquidIL::Context.new
    assert_equal "hi world", ctx.render("hi {{ x }}", "x" => "world")
  end

  def test_context_bracket_caches
    ctx = LiquidIL::Context.new
    t1 = ctx["hello"]
    t2 = ctx["hello"]
    assert_same t1, t2
  end

  def test_context_clear_cache
    ctx = LiquidIL::Context.new
    t1 = ctx["hello"]
    ctx.clear_cache
    t2 = ctx["hello"]
    refute_same t1, t2
  end
end

# ════════════════════════════════════════════════════════════
# 3. TEMPLATE — RENDERING API
# ════════════════════════════════════════════════════════════

class TemplateRenderAPITest < Minitest::Test
  def test_render_with_hash
    t = LiquidIL::Template.parse("{{ x }}")
    assert_equal "42", t.render("x" => 42)
  end

  def test_render_with_symbol_keys
    t = LiquidIL::Template.parse("{{ x }}")
    assert_equal "42", t.render(x: 42)
  end

  def test_render_with_extra_assigns
    t = LiquidIL::Template.parse("{{ x }} {{ y }}")
    assert_equal "1 2", t.render({ "x" => 1 }, y: 2)
  end

  def test_render_with_render_errors_true
    t = LiquidIL::Template.parse("{{ x | truncate: 1.5 }}")
    result = t.render({ "x" => "hello" }, render_errors: true)
    assert_includes result, "Liquid error"
  end

  def test_render_with_render_errors_false
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ missing }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render({}, render_errors: false) }
  end

  def test_render_bang
    t = LiquidIL::Template.parse("hello")
    assert_equal "hello", t.render!
  end

  def test_render_bang_raises
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ missing }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}) }
  end

  def test_render_with_registers
    ctx = LiquidIL::Context.new(registers: { a: 1 })
    t = ctx.parse("hello")
    assert_equal "hello", t.render({}, registers: { b: 2 })
  end

  def test_render_with_strict_variables_override
    t = LiquidIL::Template.parse("{{ missing }}")
    # default: no error
    assert_equal "", t.render({})
    # override: error
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}, strict_variables: true) }
  end

  def test_render_with_strict_filters_override
    t = LiquidIL::Template.parse("{{ x | bogus }}")
    # default: passes through
    assert_equal "1", t.render("x" => 1)
    # override: error
    assert_raises(LiquidIL::UndefinedFilter) { t.render!({ "x" => 1 }, strict_filters: true) }
  end
end

# ════════════════════════════════════════════════════════════
# 4. TEMPLATE — INTROSPECTION
# ════════════════════════════════════════════════════════════

class TemplateIntrospectionTest < Minitest::Test
  def test_template_has_source
    t = LiquidIL::Template.parse("hello {{ x }}")
    assert_equal "hello {{ x }}", t.source
  end

  def test_template_has_compiled_source
    t = LiquidIL::Template.parse("hello")
    assert_kind_of String, t.compiled_source
    assert_includes t.compiled_source, "proc do"
  end

  def test_template_has_instructions
    t = LiquidIL::Template.parse("hello")
    assert_kind_of Array, t.instructions
  end

  def test_template_has_errors
    t = LiquidIL::Template.parse("hello")
    assert_kind_of Array, t.errors
    assert_empty t.errors
  end

  def test_template_has_warnings
    t = LiquidIL::Template.parse("hello")
    assert_kind_of Array, t.warnings
    assert_empty t.warnings
  end

  def test_template_to_ruby
    t = LiquidIL::Template.parse("hello {{ x }}")
    ruby_src = t.to_ruby("MyTemplate")
    assert_includes ruby_src, "module MyTemplate"
    assert_includes ruby_src, "def render"
  end

  def test_template_write_ruby
    t = LiquidIL::Template.parse("hello {{ x }}")
    path = "/tmp/liquid_il_test_output.rb"
    t.write_ruby(path, module_name: "TestOut")
    content = File.read(path)
    assert_includes content, "module TestOut"
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_template_dump_il
    t = LiquidIL::Template.parse("hello {{ x }}")
    # dump_il outputs to IO — just verify it doesn't raise
    output = StringIO.new
    t.dump_il(output)
    refute_empty output.string
  end

  def test_template_il_to_s
    t = LiquidIL::Template.parse("hello {{ x }}")
    s = t.il_to_s(color: false)
    assert_includes s, "WRITE_RAW"
  end
end

# ════════════════════════════════════════════════════════════
# 5. REGISTER_FILTER — PURE
# ════════════════════════════════════════════════════════════

module PureTestFilters
  def double(input)
    (input.to_f * 2).to_s
  end

  def shout(input)
    input.to_s.upcase + "!!!"
  end

  def add(input, n)
    (input.to_f + n.to_f).to_s
  end

  def greet(input, greeting = "Hello")
    "#{greeting}, #{input}!"
  end
end

class RegisterPureFilterTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
    @ctx.register_filter(PureTestFilters, pure: true)
  end

  def test_basic
    assert_equal "84.0", @ctx.render("{{ x | double }}", "x" => 42)
  end

  def test_with_string
    assert_equal "HELLO!!!", @ctx.render("{{ x | shout }}", "x" => "hello")
  end

  def test_with_argument
    assert_equal "52.0", @ctx.render("{{ x | add: 10 }}", "x" => 42)
  end

  def test_with_default_argument
    assert_equal "Hello, World!", @ctx.render('{{ x | greet }}', "x" => "World")
  end

  def test_with_explicit_argument
    assert_equal "Hi, World!", @ctx.render('{{ x | greet: "Hi" }}', "x" => "World")
  end

  def test_chained_with_builtin
    assert_equal "84.0", @ctx.render("{{ x | double | strip }}", "x" => 42)
  end

  def test_chained_pure_filters
    assert_equal "84.0!!!", @ctx.render("{{ x | double | shout }}", "x" => 42)
  end

  def test_in_for_loop
    result = @ctx.render("{% for i in items %}{{ i | double }},{% endfor %}", "items" => [1, 2, 3])
    assert_equal "2.0,4.0,6.0,", result
  end

  def test_in_if_condition_output
    result = @ctx.render("{% if true %}{{ x | shout }}{% endif %}", "x" => "yes")
    assert_equal "YES!!!", result
  end

  def test_in_assign
    result = @ctx.render("{% assign y = x | double %}{{ y }}", "x" => 5)
    assert_equal "10.0", result
  end

  def test_registered_methods
    assert @ctx.custom_filters.key?("double")
    assert @ctx.custom_filters.key?("shout")
    assert @ctx.custom_filters.key?("add")
    assert @ctx.custom_filters.key?("greet")
  end

  def test_pure_flag
    assert_equal true, @ctx.custom_filters["double"][:pure]
  end

  def test_filter_known
    assert @ctx.filter_known?("double")
    assert @ctx.filter_known?("upcase")  # builtin
    refute @ctx.filter_known?("nonexistent")
  end
end

# ════════════════════════════════════════════════════════════
# 6. REGISTER_FILTER — IMPURE
# ════════════════════════════════════════════════════════════

module ImpureTestFilters
  def tag_it(input)
    "[tagged] #{input}"
  end
end

class RegisterImpureFilterTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
    @ctx.register_filter(ImpureTestFilters)
  end

  def test_basic
    assert_equal "[tagged] hello", @ctx.render("{{ x | tag_it }}", "x" => "hello")
  end

  def test_impure_flag
    assert_equal false, @ctx.custom_filters["tag_it"][:pure]
  end

  def test_chained_with_builtin
    assert_equal "[TAGGED] HELLO", @ctx.render("{{ x | tag_it | upcase }}", "x" => "hello")
  end

  def test_chained_with_pure
    ctx = LiquidIL::Context.new
    ctx.register_filter(PureTestFilters, pure: true)
    ctx.register_filter(ImpureTestFilters)
    assert_equal "[tagged] HELLO!!!", ctx.render("{{ x | shout | tag_it }}", "x" => "hello")
  end

  def test_in_partial
    fs = SimpleFS.new("p" => "{{ x | tag_it }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    ctx.register_filter(ImpureTestFilters)
    result = ctx.render("{% render 'p' %}", "x" => "hi")
    # Partials get their own scope but filters should still work
    # (x won't be in scope for isolated render, so input is "")
    assert_includes result, "[tagged]"
  end
end

# ════════════════════════════════════════════════════════════
# 7. REGISTER_FILTER — EDGE CASES
# ════════════════════════════════════════════════════════════

class RegisterFilterEdgeCasesTest < Minitest::Test
  def test_requires_module
    ctx = LiquidIL::Context.new
    assert_raises(ArgumentError) { ctx.register_filter("string") }
    assert_raises(ArgumentError) { ctx.register_filter(42) }
    assert_raises(ArgumentError) { ctx.register_filter(nil) }
  end

  def test_multiple_modules
    mod1 = Module.new { def filter_a(i); "a:#{i}"; end }
    mod2 = Module.new { def filter_b(i); "b:#{i}"; end }
    ctx = LiquidIL::Context.new
    ctx.register_filter(mod1, pure: true)
    ctx.register_filter(mod2, pure: true)
    assert_equal "a:x", ctx.render("{{ x | filter_a }}", "x" => "x")
    assert_equal "b:x", ctx.render("{{ x | filter_b }}", "x" => "x")
  end

  def test_custom_filter_overrides_passthrough_for_unknown
    ctx = LiquidIL::Context.new
    # Before registration, unknown filter returns input
    assert_equal "hello", ctx.render("{{ x | custom }}", "x" => "hello")
    # After registration
    ctx.register_filter(Module.new { def custom(i); "custom:#{i}"; end }, pure: true)
    assert_equal "custom:hello", ctx.render("{{ x | custom }}", "x" => "hello")
  end

  def test_custom_filter_does_not_override_builtin
    ctx = LiquidIL::Context.new
    # upcase is builtin — registering a module with upcase shouldn't break it
    # (builtins take precedence in the compiler)
    ctx.register_filter(Module.new { def upcase(i); "CUSTOM"; end }, pure: true)
    # The builtin upcase is checked first at compile time via Filters.valid_filter_methods
    result = ctx.render("{{ x | upcase }}", "x" => "hello")
    assert_equal "HELLO", result
  end

  def test_filter_error_handling
    mod = Module.new { def explode(i); raise "boom"; end }
    ctx = LiquidIL::Context.new
    ctx.register_filter(mod)
    result = ctx.render("{{ x | explode }}", "x" => "hi")
    # Should be caught and rendered as error
    assert_includes result, "Liquid error"
  end

  def test_cache_invalidation
    ctx = LiquidIL::Context.new
    _ = ctx["{{ x | custom }}"]  # Cache template
    ctx.register_filter(Module.new { def custom(i); "ok"; end }, pure: true)
    # Cache should be cleared — new parse with filter
    t = ctx.parse("{{ x | custom }}")
    assert_equal "ok", t.render("x" => "hi")
  end
end

# ════════════════════════════════════════════════════════════
# 8. REGISTER_TAG — MODES
# ════════════════════════════════════════════════════════════

class RegisterTagTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    # Re-register built-ins
    LiquidIL::Tags.register "style",  end_tag: "endstyle",  mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form",   end_tag: "endform",   mode: :passthrough
  end

  # --- Passthrough ---

  def test_passthrough_evaluates_body
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrapper", mode: :passthrough)
    assert_equal "hello world", ctx.render("{% wrapper %}hello {{ x }}{% endwrapper %}", "x" => "world")
  end

  def test_passthrough_with_setup_teardown
    ctx = LiquidIL::Context.new
    ctx.register_tag("box", mode: :passthrough,
      setup: ->(args, builder) { builder.write_raw("<box>") },
      teardown: ->(args, builder) { builder.write_raw("</box>") })
    assert_equal "<box>content</box>", ctx.render("{% box %}content{% endbox %}")
  end

  def test_passthrough_setup_receives_args
    received = nil
    ctx = LiquidIL::Context.new
    ctx.register_tag("mytag", mode: :passthrough,
      setup: ->(args, builder) { received = args })
    ctx.render("{% mytag some arguments %}body{% endmytag %}")
    assert_equal "some arguments", received.strip
  end

  def test_passthrough_with_liquid_inside
    ctx = LiquidIL::Context.new
    ctx.register_tag("section", mode: :passthrough)
    result = ctx.render("{% section %}{% for i in items %}{{ i }}{% endfor %}{% endsection %}", "items" => [1, 2])
    assert_equal "12", result
  end

  def test_passthrough_nested
    ctx = LiquidIL::Context.new
    ctx.register_tag("outer", mode: :passthrough)
    ctx.register_tag("inner", mode: :passthrough)
    result = ctx.render("{% outer %}[{% inner %}x{% endinner %}]{% endouter %}")
    assert_equal "[x]", result
  end

  # --- Discard ---

  def test_discard_skips_body
    ctx = LiquidIL::Context.new
    ctx.register_tag("config", mode: :discard)
    assert_equal "beforeafter", ctx.render("before{% config %}secret{% endconfig %}after")
  end

  def test_discard_ignores_liquid_in_body
    ctx = LiquidIL::Context.new
    ctx.register_tag("hidden", mode: :discard)
    assert_equal "", ctx.render("{% hidden %}{{ name }}{% for i in x %}{% endfor %}{% endhidden %}")
  end

  # --- Raw ---

  def test_raw_captures_literal_text
    ctx = LiquidIL::Context.new
    ctx.register_tag("verbatim", mode: :raw)
    assert_equal "{{ x }}", ctx.render("{% verbatim %}{{ x }}{% endverbatim %}")
  end

  def test_raw_does_not_evaluate_tags
    ctx = LiquidIL::Context.new
    ctx.register_tag("code", mode: :raw)
    result = ctx.render("{% code %}{% if true %}yes{% endif %}{% endcode %}")
    assert_equal "{% if true %}yes{% endif %}", result
  end

  def test_raw_preserves_whitespace
    ctx = LiquidIL::Context.new
    ctx.register_tag("pre", mode: :raw)
    result = ctx.render("{% pre %}  hello\n  world{% endpre %}")
    assert_equal "  hello\n  world", result
  end

  # --- Custom end tag ---

  def test_custom_end_tag
    ctx = LiquidIL::Context.new
    ctx.register_tag("block", end_tag: "endblock", mode: :passthrough)
    assert_equal "ok", ctx.render("{% block %}ok{% endblock %}")
  end

  # --- Built-in registered tags ---

  def test_builtin_style_tag
    assert_equal "body{}", LiquidIL::Template.parse("{% style %}body{}{% endstyle %}").render
  end

  def test_builtin_schema_tag_discards
    assert_equal "", LiquidIL::Template.parse('{% schema %}{"x":1}{% endschema %}').render
  end

  # --- Registration API ---

  def test_registered_via_context
    ctx = LiquidIL::Context.new
    ctx.register_tag("foo", mode: :passthrough)
    assert LiquidIL::Tags.registered?("foo")
  end

  def test_global_registration
    LiquidIL::Tags.register("global_tag", end_tag: "endglobal_tag", mode: :passthrough)
    assert LiquidIL::Tags.registered?("global_tag")
    assert LiquidIL::Tags.end_tag?("endglobal_tag")
  end
end

# ════════════════════════════════════════════════════════════
# 9. STRICT_FILTERS
# ════════════════════════════════════════════════════════════

class StrictFiltersTest < Minitest::Test
  def test_raises_on_unknown_filter
    ctx = LiquidIL::Context.new(strict_filters: true)
    t = ctx.parse("{{ x | bogus }}")
    assert_raises(LiquidIL::UndefinedFilter) { t.render!("x" => 1) }
  end

  def test_allows_builtins
    ctx = LiquidIL::Context.new(strict_filters: true)
    assert_equal "HELLO", ctx.render("{{ x | upcase }}", "x" => "hello")
  end

  def test_allows_registered_pure
    ctx = LiquidIL::Context.new(strict_filters: true)
    ctx.register_filter(PureTestFilters, pure: true)
    assert_equal "84.0", ctx.render("{{ x | double }}", "x" => 42)
  end

  def test_allows_registered_impure
    ctx = LiquidIL::Context.new(strict_filters: true)
    ctx.register_filter(ImpureTestFilters)
    assert_equal "[tagged] hi", ctx.render("{{ x | tag_it }}", "x" => "hi")
  end

  def test_inline_error_with_render_errors
    ctx = LiquidIL::Context.new(strict_filters: true)
    result = ctx.parse("{{ x | nope }}").render("x" => 1)
    assert_includes result, "undefined filter nope"
  end

  def test_per_render_override
    t = LiquidIL::Template.parse("{{ x | nope }}")
    assert_equal "1", t.render("x" => 1)
    assert_raises(LiquidIL::UndefinedFilter) { t.render!({ "x" => 1 }, strict_filters: true) }
  end

  def test_chained_with_unknown
    ctx = LiquidIL::Context.new(strict_filters: true)
    t = ctx.parse("{{ x | upcase | bogus }}")
    assert_raises(LiquidIL::UndefinedFilter) { t.render!("x" => "hi") }
  end
end

# ════════════════════════════════════════════════════════════
# 10. STRICT_VARIABLES
# ════════════════════════════════════════════════════════════

class StrictVariablesTest < Minitest::Test
  def test_raises_on_undefined
    ctx = LiquidIL::Context.new(strict_variables: true)
    t = ctx.parse("{{ missing }}")
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}) }
  end

  def test_allows_defined
    ctx = LiquidIL::Context.new(strict_variables: true)
    assert_equal "ok", ctx.render("{{ x }}", "x" => "ok")
  end

  def test_allows_nil_value
    ctx = LiquidIL::Context.new(strict_variables: true)
    # Explicitly set to nil: defined, should not raise
    assert_equal "", ctx.render("{{ x }}", "x" => nil)
  end

  def test_inline_error_with_render_errors
    ctx = LiquidIL::Context.new(strict_variables: true)
    result = ctx.parse("{{ missing }}").render({})
    assert_includes result, "undefined variable missing"
  end

  def test_per_render_override
    t = LiquidIL::Template.parse("{{ missing }}")
    assert_equal "", t.render({})
    assert_raises(LiquidIL::UndefinedVariable) { t.render!({}, strict_variables: true) }
  end

  def test_works_in_partials
    fs = SimpleFS.new("p" => "{{ missing }}")
    ctx = LiquidIL::Context.new(file_system: fs, strict_variables: true)
    result = ctx.parse("{% render 'p' %}").render({})
    assert_includes result, "undefined variable missing"
  end

  def test_loop_variables_are_defined
    ctx = LiquidIL::Context.new(strict_variables: true)
    result = ctx.render("{% for i in items %}{{ i }}{% endfor %}", "items" => [1, 2])
    assert_equal "12", result
  end

  def test_assigned_variables_are_defined
    ctx = LiquidIL::Context.new(strict_variables: true)
    result = ctx.render("{% assign x = 1 %}{{ x }}")
    assert_equal "1", result
  end

  def test_captured_variables_are_defined
    ctx = LiquidIL::Context.new(strict_variables: true)
    result = ctx.render("{% capture x %}hello{% endcapture %}{{ x }}")
    assert_equal "hello", result
  end
end

# ════════════════════════════════════════════════════════════
# 11. ERROR_MODE
# ════════════════════════════════════════════════════════════

class ErrorModeTest < Minitest::Test
  def test_default_is_lax
    ctx = LiquidIL::Context.new
    assert_equal :lax, ctx.error_mode
  end

  def test_lax_ignores_unknown_tags
    ctx = LiquidIL::Context.new(error_mode: :lax)
    assert_equal "beforeafter", ctx.render("before{% bogus %}after")
  end

  def test_strict_raises_on_unknown_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    assert_raises(LiquidIL::SyntaxError) { ctx.parse("{% bogus %}") }
  end

  def test_strict_error_message
    ctx = LiquidIL::Context.new(error_mode: :strict)
    err = assert_raises(LiquidIL::SyntaxError) { ctx.parse("{% bogus %}") }
    assert_includes err.message, "Unknown tag 'bogus'"
  end

  def test_strict_allows_known_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    assert_equal "yes", ctx.render("{% if true %}yes{% endif %}")
  end

  def test_strict_allows_registered_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    ctx.register_tag("known", mode: :passthrough)
    assert_equal "ok", ctx.render("{% known %}ok{% endknown %}")
  end

  def test_warn_collects_warnings
    ctx = LiquidIL::Context.new(error_mode: :warn)
    t = ctx.parse("{% a %}{% b %}{% c %}")
    assert_equal 3, t.warnings.length
    assert_includes t.warnings[0], "a"
    assert_includes t.warnings[1], "b"
    assert_includes t.warnings[2], "c"
  end

  def test_warn_still_renders
    ctx = LiquidIL::Context.new(error_mode: :warn)
    assert_equal "beforeafter", ctx.render("before{% bogus %}after")
  end

  def test_warn_known_tags_dont_warn
    ctx = LiquidIL::Context.new(error_mode: :warn)
    t = ctx.parse("{% if true %}x{% endif %}")
    assert_empty t.warnings
  end
end

# ════════════════════════════════════════════════════════════
# 12. RESOURCE LIMITS
# ════════════════════════════════════════════════════════════

class ResourceLimitsTest < Minitest::Test
  def test_render_score_limit
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 10 })
    result = ctx.render("{% for i in (1..100) %}x{% endfor %}")
    assert_includes result, "Rendering limits exceeded"
  end

  def test_render_score_nested_loops
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 20 })
    result = ctx.render("{% for i in (1..10) %}{% for j in (1..10) %}x{% endfor %}{% endfor %}")
    assert_includes result, "Rendering limits exceeded"
  end

  def test_output_limit
    ctx = LiquidIL::Context.new(resource_limits: { output_limit: 20 })
    result = ctx.render("{% for i in (1..100) %}hello{% endfor %}")
    assert_includes result, "Memory limits exceeded"
  end

  def test_output_limit_in_partial
    fs = SimpleFS.new("loop" => "{% for i in (1..100) %}x{% endfor %}")
    ctx = LiquidIL::Context.new(file_system: fs, resource_limits: { output_limit: 30 })
    result = ctx.render("start{% render 'loop' %}end")
    assert_includes result, "Memory limits exceeded"
  end

  def test_tablerow_counts_score
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 5 })
    result = ctx.render("{% tablerow i in (1..100) cols:3 %}{{ i }}{% endtablerow %}")
    assert_includes result, "Rendering limits exceeded"
  end

  def test_no_limits_zero_overhead
    t = LiquidIL::Template.parse("{% for i in (1..5) %}x{% endfor %}")
    refute_includes t.compiled_source, "increment_render_score"
    refute_includes t.compiled_source, "check_output_limit"
  end

  def test_limits_emits_checks
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 1000 })
    t = ctx.parse("{% for i in (1..5) %}x{% endfor %}")
    assert_includes t.compiled_source, "increment_render_score"
  end

  def test_render_bang_raises_on_limit
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 5 })
    t = ctx.parse("{% for i in (1..100) %}x{% endfor %}")
    assert_raises(LiquidIL::ResourceLimitError) { t.render!({}) }
  end

  def test_small_template_under_limit
    ctx = LiquidIL::Context.new(resource_limits: { render_score_limit: 100, output_limit: 1000 })
    assert_equal "xxxxx", ctx.render("{% for i in (1..5) %}x{% endfor %}")
  end
end

# ════════════════════════════════════════════════════════════
# 13. REGISTERS
# ════════════════════════════════════════════════════════════

class RegistersTest < Minitest::Test
  def test_context_registers
    ctx = LiquidIL::Context.new(registers: { page: "home" })
    assert_equal({ page: "home" }, ctx.registers)
  end

  def test_render_time_registers_merge
    ctx = LiquidIL::Context.new(registers: { a: 1 })
    t = ctx.parse("hello")
    # Should not raise — registers flow through
    assert_equal "hello", t.render({}, registers: { b: 2 })
  end

  def test_render_time_registers_override
    ctx = LiquidIL::Context.new(registers: { a: 1, b: 2 })
    t = ctx.parse("hello")
    assert_equal "hello", t.render({}, registers: { a: 99 })
  end

  def test_registers_empty_by_default
    ctx = LiquidIL::Context.new
    assert_equal({}, ctx.registers)
  end
end

# ════════════════════════════════════════════════════════════
# 14. ERROR CLASSES
# ════════════════════════════════════════════════════════════

class ErrorClassesTest < Minitest::Test
  def test_syntax_error
    assert_kind_of LiquidIL::Error, LiquidIL::SyntaxError.new("test")
    assert_kind_of StandardError, LiquidIL::SyntaxError.new("test")
  end

  def test_syntax_error_with_position
    e = LiquidIL::SyntaxError.new("bad", position: 10, source: "0123456789bad")
    assert_equal 10, e.position
    assert_equal 1, e.line
  end

  def test_syntax_error_line_number
    # position 12 = start of "bad" on line 3
    e = LiquidIL::SyntaxError.new("bad", position: 12, source: "line1\nline2\nbad")
    assert_equal 3, e.line
  end

  def test_runtime_error
    e = LiquidIL::RuntimeError.new("oops", file: "test.liquid", line: 5)
    assert_equal "oops", e.message
    assert_equal "test.liquid", e.file
    assert_equal 5, e.line
  end

  def test_undefined_filter
    e = LiquidIL::UndefinedFilter.new("undefined filter foo")
    assert_kind_of LiquidIL::Error, e
  end

  def test_undefined_variable
    e = LiquidIL::UndefinedVariable.new("undefined variable x")
    assert_kind_of LiquidIL::Error, e
  end

  def test_resource_limit_error
    e = LiquidIL::ResourceLimitError.new("Memory limits exceeded")
    assert_kind_of LiquidIL::Error, e
  end
end

# ════════════════════════════════════════════════════════════
# 15. FILE SYSTEM
# ════════════════════════════════════════════════════════════

class FileSystemTest < Minitest::Test
  def test_render_with_file_system
    fs = SimpleFS.new("header" => "HEADER")
    ctx = LiquidIL::Context.new(file_system: fs)
    assert_equal "HEADER", ctx.render("{% render 'header' %}")
  end

  def test_include_with_file_system
    fs = SimpleFS.new("footer" => "FOOTER {{ x }}")
    ctx = LiquidIL::Context.new(file_system: fs)
    assert_equal "FOOTER 42", ctx.render("{% include 'footer' %}", "x" => 42)
  end

  def test_render_partial_not_found
    fs = SimpleFS.new({})
    ctx = LiquidIL::Context.new(file_system: fs)
    # compile_partial raises when partial source is nil
    # With render_errors, it should still produce a template that shows the error
    result = ctx.render("{% render 'missing' %}")
    # Either inline error or raise — both are acceptable
    assert(result.include?("Liquid error") || result.include?("Cannot load"),
      "Expected error message in: #{result.inspect}")
  rescue => e
    assert_includes e.message, "Cannot load partial"
  end

  def test_no_file_system_error
    ctx = LiquidIL::Context.new
    result = ctx.render("{% render 'x' %}")
    assert_includes result, "Could not find partial"
  end
end

# ════════════════════════════════════════════════════════════
# 16. TEMPLATE.parse CLASS METHOD
# ════════════════════════════════════════════════════════════

class TemplateParseSingletonTest < Minitest::Test
  def test_parse_string
    t = LiquidIL::Template.parse("hello {{ x }}")
    assert_instance_of LiquidIL::Template, t
    assert_equal "hello world", t.render("x" => "world")
  end

  def test_parse_empty
    t = LiquidIL::Template.parse("")
    assert_equal "", t.render
  end

  def test_parse_syntax_error
    assert_raises(LiquidIL::SyntaxError) do
      LiquidIL::Template.parse("{% if %}")
    end
  end
end
