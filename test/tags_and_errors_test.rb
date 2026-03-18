# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# === register_tag ===

class RegisterTagTest < Minitest::Test
  def teardown
    # Clean up custom tags after each test
    LiquidIL::Tags.clear!
    # Re-register built-in Shopify tags
    LiquidIL::Tags.register "style",    end_tag: "endstyle",    mode: :passthrough
    LiquidIL::Tags.register "schema",   end_tag: "endschema",   mode: :discard
    LiquidIL::Tags.register "form",     end_tag: "endform",     mode: :passthrough
  end

  def test_register_passthrough_tag
    ctx = LiquidIL::Context.new
    ctx.register_tag("highlight", mode: :passthrough)
    t = ctx.parse("{% highlight %}bold{% endhighlight %}")
    assert_equal "bold", t.render({})
  end

  def test_register_passthrough_tag_with_setup_teardown
    ctx = LiquidIL::Context.new
    ctx.register_tag("box", mode: :passthrough,
      setup: ->(args, builder) { builder.write_raw("[") },
      teardown: ->(args, builder) { builder.write_raw("]") })
    t = ctx.parse("{% box %}content{% endbox %}")
    assert_equal "[content]", t.render({})
  end

  def test_register_discard_tag
    ctx = LiquidIL::Context.new
    ctx.register_tag("config", mode: :discard)
    t = ctx.parse("before{% config %}secret stuff{% endconfig %}after")
    assert_equal "beforeafter", t.render({})
  end

  def test_register_raw_tag
    ctx = LiquidIL::Context.new
    ctx.register_tag("verbatim", mode: :raw)
    t = ctx.parse("{% verbatim %}{{ not_evaluated }}{% endverbatim %}")
    assert_equal "{{ not_evaluated }}", t.render({})
  end

  def test_register_tag_with_custom_end_tag
    ctx = LiquidIL::Context.new
    ctx.register_tag("section", end_tag: "endsection", mode: :passthrough)
    t = ctx.parse("{% section %}hello{% endsection %}")
    assert_equal "hello", t.render({})
  end

  def test_built_in_style_tag
    # style is registered by default
    t = LiquidIL::Template.parse("{% style %}body { color: red; }{% endstyle %}")
    assert_equal "body { color: red; }", t.render({})
  end

  def test_built_in_schema_tag_discards_body
    t = LiquidIL::Template.parse('{% schema %}{"name":"test"}{% endschema %}')
    assert_equal "", t.render({})
  end

  def test_passthrough_tag_evaluates_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrapper", mode: :passthrough)
    t = ctx.parse("{% wrapper %}{{ name }}{% endwrapper %}")
    assert_equal "World", t.render("name" => "World")
  end
end

# === error_mode ===

class ErrorModeTest < Minitest::Test
  def test_lax_mode_ignores_unknown_tags
    ctx = LiquidIL::Context.new(error_mode: :lax)
    t = ctx.parse("before{% unknown_tag %}after")
    assert_equal "beforeafter", t.render({})
  end

  def test_strict_mode_raises_on_unknown_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    assert_raises(LiquidIL::SyntaxError) do
      ctx.parse("{% unknown_tag %}")
    end
  end

  def test_strict_mode_error_has_position
    ctx = LiquidIL::Context.new(error_mode: :strict)
    begin
      ctx.parse("hello {% bad_tag %}")
      flunk "Should have raised"
    rescue LiquidIL::SyntaxError => e
      assert_match(/Unknown tag 'bad_tag'/, e.message)
    end
  end

  def test_warn_mode_collects_warnings
    ctx = LiquidIL::Context.new(error_mode: :warn)
    t = ctx.parse("{% unknown1 %}{% unknown2 %}")
    assert_equal 2, t.warnings.length
    assert_match(/unknown1/, t.warnings[0])
    assert_match(/unknown2/, t.warnings[1])
  end

  def test_warn_mode_still_renders
    ctx = LiquidIL::Context.new(error_mode: :warn)
    t = ctx.parse("before{% unknown %}after")
    assert_equal "beforeafter", t.render({})
  end

  def test_default_is_lax
    ctx = LiquidIL::Context.new
    assert_equal :lax, ctx.error_mode
  end

  def test_strict_mode_allows_known_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    t = ctx.parse("{% if true %}yes{% endif %}")
    assert_equal "yes", t.render({})
  end

  def test_strict_mode_allows_registered_tags
    ctx = LiquidIL::Context.new(error_mode: :strict)
    ctx.register_tag("custom", mode: :passthrough)
    t = ctx.parse("{% custom %}ok{% endcustom %}")
    assert_equal "ok", t.render({})
  end
end

# === Template#errors / #warnings ===

class TemplateErrorsTest < Minitest::Test
  def test_template_has_errors_accessor
    t = LiquidIL::Template.parse("hello")
    assert_respond_to t, :errors
    assert_kind_of Array, t.errors
  end

  def test_template_has_warnings_accessor
    t = LiquidIL::Template.parse("hello")
    assert_respond_to t, :warnings
    assert_kind_of Array, t.warnings
  end

  def test_valid_template_has_no_warnings
    t = LiquidIL::Template.parse("{{ name | upcase }}")
    assert_empty t.warnings
  end

  def test_warn_mode_populates_warnings
    ctx = LiquidIL::Context.new(error_mode: :warn)
    t = ctx.parse("{% bogus %}")
    assert_equal 1, t.warnings.length
  end
end
