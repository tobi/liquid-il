# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class DynamicRenderTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    # Re-register built-in tags that clear! removed
    LiquidIL::Tags.register "style",    end_tag: "endstyle",    mode: :passthrough
    LiquidIL::Tags.register "schema",   end_tag: "endschema",   mode: :discard
    LiquidIL::Tags.register "form",     end_tag: "endform",     mode: :passthrough
  end

  # --- Handler for testing ---

  module TestDynamicRenderHandler
    class << self
      def render(scope, output, name)
        output << "[dynamic:#{name}]"
      end
    end
  end

  # Tracks calls for assertion
  module TrackingHandler
    @calls = []
    class << self
      attr_reader :calls

      def render(scope, output, name)
        @calls << name
        output << "rendered:#{name}"
      end

      def reset!
        @calls.clear
      end
    end
  end

  # --- Registration ---

  def test_register_dynamic_render_handler
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    assert_equal TestDynamicRenderHandler, LiquidIL::Tags.dynamic_render_handler
  end

  def test_clear_resets_dynamic_render_handler
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    LiquidIL::Tags.clear!
    assert_nil LiquidIL::Tags.dynamic_render_handler
  end

  # --- Parsing ---

  def test_render_with_variable_raises_without_handler
    ctx = LiquidIL::Context.new
    assert_raises(LiquidIL::SyntaxError) do
      ctx.parse("{% render my_var %}")
    end
  end

  def test_render_with_string_still_works
    # Static render should be unaffected regardless of handler registration
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new(file_system: nil)
    # This should parse without error (even though it can't resolve the partial)
    template = ctx.parse("{% render 'missing' %}")
    # Renders an error because there's no file system, but doesn't crash
    result = template.render({})
    assert_match(/Could not find/, result)
  end

  # --- Rendering ---

  def test_dynamic_render_simple_variable
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render my_var %}")
    result = template.render({ "my_var" => "snippet-header" })
    assert_equal "[dynamic:snippet-header]", result
  end

  def test_dynamic_render_dotted_path
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render section.type %}")
    result = template.render({ "section" => { "type" => "hero-banner" } })
    assert_equal "[dynamic:hero-banner]", result
  end

  def test_dynamic_render_bracket_access
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render sections[0] %}")
    result = template.render({ "sections" => ["slideshow"] })
    assert_equal "[dynamic:slideshow]", result
  end

  def test_dynamic_render_with_surrounding_content
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("before{% render name %}after")
    result = template.render({ "name" => "footer" })
    assert_equal "before[dynamic:footer]after", result
  end

  def test_dynamic_render_handler_receives_scope
    handler = Module.new do
      class << self
        def render(scope, output, name)
          # Access a variable through scope to verify it's the real scope
          val = scope.lookup("greeting")
          output << "#{val} via #{name}"
        end
      end
    end

    LiquidIL::Tags.register_dynamic_render_handler(handler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render template_name %}")
    result = template.render({ "greeting" => "hello", "template_name" => "my-section" })
    assert_equal "hello via my-section", result
  end

  def test_dynamic_render_multiple_calls
    TrackingHandler.reset!
    LiquidIL::Tags.register_dynamic_render_handler(TrackingHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render a %}|{% render b %}")
    result = template.render({ "a" => "first", "b" => "second" })
    assert_equal "rendered:first|rendered:second", result
    assert_equal ["first", "second"], TrackingHandler.calls
  end

  def test_dynamic_render_inside_for_loop
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% for name in names %}{% render name %}{% endfor %}")
    result = template.render({ "names" => ["a", "b", "c"] })
    assert_equal "[dynamic:a][dynamic:b][dynamic:c]", result
  end

  def test_dynamic_render_with_nil_value
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% render missing_var %}")
    result = template.render({})
    assert_equal "[dynamic:]", result
  end

  def test_dynamic_render_inside_conditional
    LiquidIL::Tags.register_dynamic_render_handler(TestDynamicRenderHandler)
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% if show %}{% render name %}{% endif %}")
    result = template.render({ "show" => true, "name" => "visible" })
    assert_equal "[dynamic:visible]", result

    result = template.render({ "show" => false, "name" => "hidden" })
    assert_equal "", result
  end
end
