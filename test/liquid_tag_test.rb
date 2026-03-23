# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"
require_relative "helpers/parity_helper"

# Tests for custom tags (with handlers) inside {% liquid %}.
# These can't compare against OG Liquid since the handlers are liquid-il specific.
class LiquidTagCustomTagTest < Minitest::Test
  module WrapHandler
    class << self
      def before_block(scope, output, arguments)
        output << "[BEFORE]"
        {}
      end

      def after_block(scope, output, state)
        output << "[AFTER]"
      end
    end
  end

  module FormHandler
    class << self
      def before_block(scope, output, arguments)
        type = arguments[0]
        scope.push_scope
        scope["form"] = { "type" => type }
        output << "<form>"
        {}
      end

      def after_block(scope, output, state)
        output << "</form>"
        scope.pop_scope
      end
    end
  end

  def test_custom_block_tag_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrap", end_tag: "endwrap", mode: :custom, handler: WrapHandler)

    normal = ctx.render("{% wrap %}body{% endwrap %}")
    liquid = ctx.render("{% liquid\nwrap\n  echo \"body\"\nendwrap\n%}")

    assert_equal normal, liquid
    assert_equal "[BEFORE]body[AFTER]", liquid
  end

  def test_custom_block_tag_with_scope_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom, handler: FormHandler)

    normal = ctx.render("{% form 'contact' %}{{ form.type }}{% endform %}")
    liquid = ctx.render("{% liquid\nform 'contact'\n  echo form.type\nendform\n%}")

    assert_equal normal, liquid
    assert_equal "<form>contact</form>", liquid
  end

  def test_custom_block_tag_nested_in_if_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrap", end_tag: "endwrap", mode: :custom, handler: WrapHandler)

    result = ctx.render('{% liquid
if show
  wrap
    echo "inside"
  endwrap
endif
%}', { "show" => true })

    assert_equal "[BEFORE]inside[AFTER]", result
  end

  def test_discard_tag_in_liquid
    captured = nil
    LiquidIL::Tags.register("schema", end_tag: "endschema", mode: :discard,
      on_parse: ->(raw_body, _ctx) { captured = raw_body })

    ctx = LiquidIL::Context.new
    result = ctx.render('{% liquid
echo "before"
schema
  {"key": "value"}
endschema
echo "after"
%}')

    assert_equal "beforeafter", result
    refute_nil captured, "on_parse callback should have fired for discard tag inside liquid"
  end
end

# Minimal file system shared by OG Liquid and LiquidIL
class SimpleFileSystem
  def initialize(templates)
    @templates = templates
  end

  def read_template_file(name)
    @templates[name] || @templates["#{name}.liquid"] || raise("Template not found: #{name}")
  end
end
