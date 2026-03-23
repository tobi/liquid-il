# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# These tests verify that custom tags work end-to-end through the liquid-il
# pipeline: parse → compile → render. They should FAIL until we build:
#   1. :custom tag mode in Tags.register
#   2. Parser support for custom tag argument extraction
#   3. RubyCompiler emitting before_block/after_block/render calls
#   4. on_parse callbacks for parse-time side effects
#
# Each test compiles a template containing a custom tag and verifies the
# rendered output matches what the tag handler produces.

# ── Mock tag handlers ─────────────────────────────────────────────
# These implement the before_block/after_block/render API that compiled
# code will call.

module TestFormHandler
  class << self
    def before_block(scope, output, arguments)
      type = arguments[0]
      form_drop = {"type" => type, "id" => "#{type}-form"}

      prev_form = scope.registers[:form]
      scope.registers[:form] = form_drop
      scope.push_scope
      scope["form"] = form_drop
      output << "<form data-type=\"#{type}\">"

      {previous_form: prev_form}
    end

    def after_block(scope, output, state)
      output << "</form>"
      scope.pop_scope
      if state[:previous_form]
        scope.registers[:form] = state[:previous_form]
      else
        scope.registers.delete(:form)
      end
    end
  end
end

module TestStyleHandler
  class << self
    def before_block(scope, output, arguments)
      if scope.registers[:inside_style_tag]
        raise LiquidIL::RuntimeError.new("style tag cannot be nested")
      end
      scope.registers[:inside_style_tag] = true
      output << "<style data-shopify>"
      {}
    end

    def after_block(scope, output, state)
      output << "</style>"
      scope.registers.delete(:inside_style_tag)
    end
  end
end

module TestLayoutHandler
  class << self
    def render(scope, output, arguments)
      scope.registers.static[:layout] = arguments[0]
    end
  end
end

# ── Fake context for tests that need registers ────────────────────

class CustomTagTestContext
  attr_accessor :template_name
  attr_reader :registers, :static_environments, :environments, :scopes, :resource_limits

  def initialize(registers: {})
    @scopes = [{}]
    @static_environments = [{}]
    @environments = [{}]
    @registers = CustomTagTestRegisters.new(registers)
    @template_name = nil
    @resource_limits = nil
  end
end

class CustomTagTestRegisters
  attr_reader :static

  def initialize(data = {})
    @static = data.dup
    @changes = {}
  end

  def [](key)
    @changes.key?(key) ? @changes[key] : @static[key]
  end

  def []=(key, value)
    @changes[key] = value
  end

  def delete(key)
    @changes.delete(key)
  end

  def key?(key)
    @changes.key?(key) || @static.key?(key)
  end
end

# ════════════════════════════════════════════════════════════════════
# Integration tests — these should FAIL until custom tag support is built
# ════════════════════════════════════════════════════════════════════

class CustomBlockTagIntegrationTest < Minitest::Test
  def setup
    # Register custom tags with handlers
    # This is the API we need to build:
    # LiquidIL::Tags.register "form", end_tag: "endform", mode: :custom,
    #   handler: TestFormHandler,
    #   parse_args: ->(tag_args) { ... }
  end

  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # The compiled code should emit:
  #   _state = TestFormHandler.before_block(_S, _O, ["contact"])
  #   _O << _S.lookup("form")["type"]    # body
  #   TestFormHandler.after_block(_S, _O, _state)
  def test_form_tag_renders_with_before_after_block
    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: TestFormHandler)

    liquid_ctx = CustomTagTestContext.new
    scope_assigns = {}
    template = ctx.parse("{% form 'contact' %}{{ form.type }}{% endform %}")
    result = template.render(scope_assigns, liquid_context: liquid_ctx)

    assert_equal '<form data-type="contact">contact</form>', result
  end

  # Verify that assigns before the tag are visible inside the body
  def test_assign_before_form_visible_in_body

    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: TestFormHandler)

    template = ctx.parse('{% assign x = "hello" %}{% form "contact" %}{{ x }}{% endform %}')
    result = template.render({})

    assert_match(/hello/, result)
  end

  # Verify that assigns inside the body are visible after the tag
  def test_assign_inside_form_visible_after

    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: TestFormHandler)

    template = ctx.parse('{% form "contact" %}{% assign x = "hello" %}{% endform %}{{ x }}')
    result = template.render({})

    assert_match(/hello/, result)
  end

  # Style tag with before/after block
  def test_style_tag_wraps_body
    ctx = LiquidIL::Context.new
    ctx.register_tag("style", end_tag: "endstyle", mode: :custom,
      handler: TestStyleHandler)

    template = ctx.parse("{% style %}body { color: red; }{% endstyle %}")
    result = template.render({})

    assert_equal "<style data-shopify>body { color: red; }</style>", result
  end

  # Nested style should error
  def test_nested_style_raises

    ctx = LiquidIL::Context.new
    ctx.register_tag("style", end_tag: "endstyle", mode: :custom,
      handler: TestStyleHandler)

    template = ctx.parse("{% style %}{% style %}x{% endstyle %}{% endstyle %}")
    result = template.render({})

    assert_match(/nested/, result)
  end
end

class CustomNonBlockTagIntegrationTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # Layout tag is a non-block tag — just calls render()
  def test_layout_sets_register

    ctx = LiquidIL::Context.new
    ctx.register_tag("layout", mode: :custom, handler: TestLayoutHandler)

    liquid_ctx = CustomTagTestContext.new
    template = ctx.parse("{% layout 'alternate' %}")
    template.render({}, liquid_context: liquid_ctx)

    assert_equal "alternate", liquid_ctx.registers.static[:layout]
  end
end

class ParseTimeSideEffectsIntegrationTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # Schema tag should call on_parse with the raw JSON body
  def test_schema_on_parse_receives_raw_body
    captured_body = nil

    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard,
      on_parse: ->(raw_body, parse_context) {
        captured_body = raw_body
      }

    ctx = LiquidIL::Context.new
    ctx.parse('before{% schema %}{"name":"Header","class":"section"}{% endschema %}after')

    assert_equal '{"name":"Header","class":"section"}', captured_body
  end

  # Schema body should still be discarded in output
  def test_schema_body_still_discarded
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard,
      on_parse: ->(raw_body, parse_context) { }

    ctx = LiquidIL::Context.new
    template = ctx.parse('before{% schema %}{"name":"Header"}{% endschema %}after')

    assert_equal "beforeafter", template.render({})
  end

  # on_parse receives parse_context so it can write to template_with_raw_definition_tag
  def test_schema_on_parse_receives_parse_context
    received_parse_context = nil

    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard,
      on_parse: ->(raw_body, parse_context) {
        received_parse_context = parse_context
      }

    ctx = LiquidIL::Context.new
    ctx.parse('{% schema %}{}{% endschema %}')

    refute_nil received_parse_context
  end

  # JavaScript tag parse-time side effect
  def test_javascript_on_parse
    js_seen = false

    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "javascript", end_tag: "endjavascript", mode: :discard,
      on_parse: ->(raw_body, parse_context) {
        js_seen = true
      }

    ctx = LiquidIL::Context.new
    template = ctx.parse('{% javascript %}console.log("hi"){% endjavascript %}')

    assert js_seen, "on_parse should have fired"
    assert_equal "", template.render({})
  end
end

class LazyArgumentIntegrationTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # parse_args returns a mix of strings (eager) and procs (lazy).
  # The compiler should compile strings to IL expressions and pass procs through.
  # This tests that paginate's lazy collection arg is not evaluated until
  # the handler calls it.
  def test_lazy_arg_not_evaluated_until_handler_calls_it

    eval_count = 0

    # A handler that tracks when the lazy arg is evaluated
    handler = Module.new do
      define_method(:before_block) do |scope, output, arguments|
        _name, _page_size, _window_size, lazy_collection = arguments
        # Lazy arg should not have been called yet
        raise "lazy arg called too early" if eval_count > 0
        collection = lazy_collection.call(scope)
        scope.push_scope
        scope["paginate"] = {"items" => collection.length}
        {}
      end
      define_method(:after_block) do |scope, output, state|
        scope.pop_scope
      end
      module_function :before_block, :after_block
    end

    ctx = LiquidIL::Context.new
    ctx.register_tag("paginate", end_tag: "endpaginate", mode: :custom,
      handler: handler,
      parse_args: ->(markup) {
        # "products by 4" → eager name, eager page_size, lazy collection
        match = markup.match(/(\S+)\s+by\s+(\S+)/)
        var_name = match[1]
        page_size = match[2]
        lazy = ->(scope) {
          eval_count += 1
          scope.find_variable(var_name)
        }
        [var_name, page_size, nil, lazy]
      })

    template = ctx.parse("{% paginate products by 4 %}{{ paginate.items }}{% endpaginate %}")
    result = template.render({"products" => (1..10).to_a})

    assert_equal "10", result
    assert_equal 1, eval_count, "Lazy arg should have been called exactly once"
  end

  # Lazy arg should see current scope state at call time, not parse time.
  # If an assign happens before the tag, the lazy arg sees the assigned value.
  def test_lazy_arg_sees_runtime_assigns

    handler = Module.new do
      define_method(:before_block) do |scope, output, arguments|
        lazy = arguments[0]
        value = lazy.call(scope)
        output << value.to_s
        scope.push_scope
        {}
      end
      define_method(:after_block) do |scope, output, state|
        scope.pop_scope
      end
      module_function :before_block, :after_block
    end

    ctx = LiquidIL::Context.new
    ctx.register_tag("mytag", end_tag: "endmytag", mode: :custom,
      handler: handler,
      parse_args: ->(markup) {
        [->(scope) { scope.find_variable("x") }]
      })

    template = ctx.parse('{% assign x = "hello" %}{% mytag %}{% endmytag %}')
    result = template.render({})

    assert_equal "hello", result
  end

  # Eager string args get compiled to IL. Proc args pass through.
  # The compiler should handle both in the same arguments array.
  def test_mixed_eager_and_lazy_in_same_tag

    handler = Module.new do
      define_method(:render) do |scope, output, arguments|
        eager_type, lazy_collection = arguments
        output << "type=#{eager_type},"
        items = lazy_collection.call(scope)
        output << "count=#{items.length}"
      end
      module_function :render
    end

    ctx = LiquidIL::Context.new
    ctx.register_tag("mytag", mode: :custom,
      handler: handler,
      parse_args: ->(markup) {
        # "'blocks'" is eager (string literal), collection lookup is lazy
        type = markup.match(/('[\w]+')/)[1]
        [type, ->(scope) { scope.find_variable("items") }]
      })

    template = ctx.parse("{% mytag 'blocks' %}")
    result = template.render({"items" => [1, 2, 3]})

    assert_equal "type=blocks,count=3", result
  end
end
