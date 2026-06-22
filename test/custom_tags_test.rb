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

  # Arrays and Hashes should be passed through as lazy arguments (like Procs)
  # but unlike Procs they are serializable and can be cached.
  # This is important for tags like {% form 'localization', id: 'my-form' %}
  # where the attributes are parsed into an Array of [key, value] pairs.
  def test_array_argument_passed_through_to_handler
    handler = Module.new do
      define_method(:before_block) do |scope, output, arguments|
        type, _variable, tag_attrs = arguments
        output << "<form type=\"#{type}\""
        if tag_attrs.is_a?(Array)
          tag_attrs.each do |key, value|
            output << " #{key}=\"#{value}\""
          end
        end
        output << ">"
        scope.push_scope
        {}
      end
      define_method(:after_block) do |scope, output, state|
        output << "</form>"
        scope.pop_scope
      end
      module_function :before_block, :after_block
    end

    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: handler,
      parse_args: ->(markup) {
        # Parse: 'localization', id: 'my-form', class: 'custom-class'
        type = markup.match(/'(\w+)'/)[1]
        attrs = []
        markup.scan(/([\w-]+):\s*'([^']*)'/) do |key, value|
          # Store key-value pairs in an array (like form tag attributes)
          attrs << [key, value]
        end
        # Return type as a quoted expression string so it compiles to a literal
        ["'#{type}'", nil, attrs]
      })

    template = ctx.parse("{% form 'localization', id: 'my-form', class: 'custom-class' %}BODY{% endform %}")
    result = template.render({})

    assert_equal '<form type="localization" id="my-form" class="custom-class">BODY</form>', result
  end

  # Hash arguments should also be passed through
  def test_hash_argument_passed_through_to_handler
    handler = Module.new do
      define_method(:before_block) do |scope, output, arguments|
        name, metadata = arguments
        output << "name=#{name}"
        if metadata.is_a?(Hash)
          output << ",method=#{metadata[:method_name]}"
          output << ",page_size=#{metadata[:page_size]}"
        end
        scope.push_scope
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
        # Parse: collection.products by 4
        match = markup.match(/(\S+)\s+by\s+(\d+)/)
        var_name = match[1]
        page_size = match[2].to_i
        method_name = var_name.split(".").last
        # Pass metadata as a hash (serializable unlike Proc)
        # Return var_name as quoted string so it compiles to literal
        ["'#{var_name}'", { method_name: method_name, page_size: page_size }]
      })

    template = ctx.parse("{% paginate collection.products by 4 %}{% endpaginate %}")
    result = template.render({})

    assert_equal "name=collection.products,method=products,page_size=4", result
  end
end

# ── File system for partial rendering tests ──────────────────────
class HashFileSystem
  def initialize(partials)
    @partials = partials
  end

  def read_template_file(name)
    @partials.fetch(name) { raise Liquid::FileSystemError, "No such template '#{name}'" }
  end
end

class CustomTagPartialCollisionTest < Minitest::Test
  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # Regression: when a parent template has {% style %} and a rendered partial
  # has {% form %}, both custom block tags get compiled with the same
  # __custom_handler_0__ key. Since the partial's code is inlined, it picks up
  # the parent's handler (StyleIlHandler) instead of its own (FormIlHandler).
  def test_partial_custom_tag_handler_does_not_collide_with_parent
    fs = HashFileSystem.new(
      "buy-buttons" => "{% form 'product' %}FORM_BODY{% endform %}"
    )

    ctx = LiquidIL::Context.new(file_system: fs)
    ctx.register_tag("style", end_tag: "endstyle", mode: :custom,
      handler: TestStyleHandler)
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: TestFormHandler)

    template = ctx.parse("{% style %}.red{}{% endstyle %}{% render 'buy-buttons' %}")
    result = template.render({})

    assert_includes result, '<form data-type="product">',
      "Partial's {% form %} should use FormHandler, not StyleHandler"
    assert_includes result, "FORM_BODY"
    assert_includes result, "</form>"
    assert_includes result, "<style data-shopify>"
    assert_includes result, "</style>"
  end

  # Same test but with multiple custom tags in both parent and partial
  def test_multiple_custom_tags_in_parent_and_partial_no_collision
    fs = HashFileSystem.new(
      "snippet" => "{% form 'contact' %}CONTACT{% endform %}{% style %}.inner{}{% endstyle %}"
    )

    ctx = LiquidIL::Context.new(file_system: fs)
    ctx.register_tag("style", end_tag: "endstyle", mode: :custom,
      handler: TestStyleHandler)
    ctx.register_tag("form", end_tag: "endform", mode: :custom,
      handler: TestFormHandler)

    template = ctx.parse("{% style %}.outer{}{% endstyle %}{% form 'main' %}MAIN{% endform %}{% render 'snippet' %}")
    result = template.render({})

    # Parent tags
    assert_includes result, '<style data-shopify>.outer{}</style>'
    assert_includes result, '<form data-type="main">MAIN</form>'
    # Partial tags
    assert_includes result, '<form data-type="contact">CONTACT</form>'
    assert_includes result, '<style data-shopify>.inner{}</style>'
  end
end

# ════════════════════════════════════════════════════════════════════
# Custom tags inside control flow structures
# ════════════════════════════════════════════════════════════════════

# Simple handler that just records the argument passed
module TestSectionHandler
  class << self
    def render(scope, output, arguments)
      name = arguments[0]
      output << "[section:#{name.inspect}]"
    end
  end
end

class CustomTagsInControlFlowTest < Minitest::Test
  def setup
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "section", mode: :custom,
      handler: TestSectionHandler,
      parse_args: ->(markup) {
        name = markup.strip.tr(%('"), "")
        ["'#{name}'"]
      }
  end

  def teardown
    LiquidIL::Tags.clear!
    LiquidIL::Tags.register "style", end_tag: "endstyle", mode: :passthrough
    LiquidIL::Tags.register "schema", end_tag: "endschema", mode: :discard
    LiquidIL::Tags.register "form", end_tag: "endform", mode: :passthrough
  end

  # Basic case/when with custom tag should render correct section based on condition
  def test_custom_tag_in_case_when_single_branch
    template = LiquidIL.parse(<<~LIQUID)
      {% case x %}
        {% when "a" %}
          {% section 'sec-a' %}
      {% endcase %}
    LIQUID

    assert_includes template.render({"x" => "a"}), '[section:"sec-a"]'
    refute_includes template.render({"x" => "b"}), '[section:'
  end

  # Multiple when branches with custom tags - each should get correct arguments
  def test_custom_tag_in_case_when_multiple_branches
    template = LiquidIL.parse(<<~LIQUID)
      {% case x %}
        {% when "a" %}
          {% section 'sec-a' %}
        {% when "b" %}
          {% section 'sec-b' %}
        {% else %}
          {% section 'sec-default' %}
      {% endcase %}
    LIQUID

    result_a = template.render({"x" => "a"})
    assert_includes result_a, '[section:"sec-a"]'
    refute_includes result_a, '[section:"sec-b"]'
    refute_includes result_a, '[section:"sec-default"]'

    result_b = template.render({"x" => "b"})
    refute_includes result_b, '[section:"sec-a"]'
    assert_includes result_b, '[section:"sec-b"]'
    refute_includes result_b, '[section:"sec-default"]'

    result_other = template.render({"x" => "other"})
    refute_includes result_other, '[section:"sec-a"]'
    refute_includes result_other, '[section:"sec-b"]'
    assert_includes result_other, '[section:"sec-default"]'
  end

  # Custom tag inside if should only render when condition is true
  def test_custom_tag_in_if_statement
    template = LiquidIL.parse(<<~LIQUID)
      {% if show %}{% section 'header' %}{% endif %}
    LIQUID

    assert_includes template.render({"show" => true}), '[section:"header"]'
    refute_includes template.render({"show" => false}), '[section:'
  end

  # Custom tag arguments should not be nil when inside case/when
  # This is a regression test for a bug where peek_if_statement? would
  # look past CUSTOM_TAG_RENDER and find JUMP_IF_TRUE from next when-clause
  def test_custom_tag_arguments_not_nil_in_case_when
    template = LiquidIL.parse(<<~LIQUID)
      {% case x %}
        {% when "a" %}{% section 'sec-a' %}
        {% when "b" %}{% section 'sec-b' %}
      {% endcase %}
    LIQUID

    # If arguments are nil, the output would show [section:nil] instead of [section:"sec-a"]
    assert_includes template.render({"x" => "a"}), '[section:"sec-a"]'
    assert_includes template.render({"x" => "b"}), '[section:"sec-b"]'

    # Verify nil does NOT appear in output
    refute_includes template.render({"x" => "a"}), 'nil'
    refute_includes template.render({"x" => "b"}), 'nil'
  end
end
