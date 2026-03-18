# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Tests that LiquidIL::Scope implements the Liquid::Vm::Hacks::ContextShim
# API contract when given a liquid_context.

# ── Fake Liquid::Context ──────────────────────────────────────────

class FakeContext
  attr_accessor :template_name, :exception_renderer
  attr_reader :registers, :scopes, :static_environments, :environments, :errors, :resource_limits

  def initialize(assigns: {}, static_envs: {}, registers: {})
    @scopes = [assigns]
    @static_environments = [static_envs]
    @environments = [{}]
    @registers = FakeRegs.new(registers)
    @errors = []
    @template_name = nil
    @resource_limits = FakeResourceLimits.new
    @exception_renderer = ->(e) { e.message }
  end

  def paginated_drop?(drop) = drop.respond_to?(:paginate_key)
  def render_flags = @registers[:render_flags]
  def event_tracker = @registers[:event_tracker]
  def theme_render_context = @registers[:theme_render_context]
  def static_assigns = @static_environments.first
  def request = @registers[:request]
  def shop = @registers[:shop]
  def theme = @registers[:theme]

  def handle_error(e, line_number = nil)
    @errors << e
    @exception_renderer.call(e)
  end

  def new_isolated_subcontext
    FakeContext.new(
      static_envs: @static_environments.first || {},
      registers: @registers.static.dup,
    )
  end
end

class FakeRegs
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

class FakeResourceLimits
  attr_accessor :render_length_limit, :render_score_limit, :assign_score_limit

  def initialize
    @render_length_limit = 0
    @render_score_limit = 0
    @assign_score_limit = 0
  end
end

# ════════════════════════════════════════════════════════════════════
# Scope implements the liquid-vm ContextShim API contract
# ════════════════════════════════════════════════════════════════════

class ScopeContextAPIContractTest < Minitest::Test
  LIQUID_VM_SHIM_METHODS = %i[
    context template_name template_name= is_a? evaluate
    find_variable [] []= outer_assign local_assign
    stack push_scope pop_scope registers
    handle_error update_resource_limits internal_resource_limits
    new_isolated_subcontext
  ]

  def setup
    @ctx = FakeContext.new(
      assigns: {"product" => {"title" => "Widget"}},
      static_envs: {"section" => {"id" => "header"}},
      registers: {render_flags: "flags_obj"},
    )
    @scope = LiquidIL::Scope.new(
      {"product" => {"title" => "Widget"}},
      liquid_context: @ctx,
    )
  end

  def test_all_liquid_vm_methods_present
    LIQUID_VM_SHIM_METHODS.each do |method|
      assert @scope.respond_to?(method),
        "Scope must implement #{method} (liquid-vm contract)"
    end
  end

  def test_context_returns_liquid_context
    assert_equal @ctx, @scope.context
  end

  def test_template_name
    @scope.template_name = "sections/header.liquid"
    assert_equal "sections/header.liquid", @scope.template_name
  end

  def test_is_a_delegates
    assert @scope.is_a?(FakeContext)
    assert @scope.is_a?(LiquidIL::Scope)
    refute @scope.is_a?(String)
  end

  def test_find_variable_from_scope
    assert_equal({"title" => "Widget"}, @scope.find_variable("product"))
  end

  def test_find_variable_falls_through_to_context
    assert_equal({"id" => "header"}, @scope.find_variable("section"))
  end

  def test_bracket_read
    assert_equal({"title" => "Widget"}, @scope["product"])
  end

  def test_bracket_assign_is_local
    @scope.push_scope
    @scope["color"] = "red"
    assert_equal "red", @scope.lookup("color")
    @scope.pop_scope
    assert_nil @scope.lookup("color")
  end

  def test_outer_assign
    @scope.outer_assign("x", 1)
    assert_equal 1, @scope.lookup("x")
  end

  def test_local_assign
    @scope.push_scope
    @scope.local_assign("y", 2)
    assert_equal 2, @scope.lookup("y")
    @scope.pop_scope
  end

  def test_stack
    @scope.stack do
      @scope["form"] = "contact"
      assert_equal "contact", @scope.find_variable("form")
    end
    assert_nil @scope.find_variable("form")
  end

  def test_evaluate_passthrough
    assert_equal "hello", @scope.evaluate("hello")
    assert_equal 42, @scope.evaluate(42)
  end

  def test_evaluate_with_evaluatable
    obj = Object.new
    def obj.evaluate(ctx) = ctx.find_variable("product")
    assert_equal({"title" => "Widget"}, @scope.evaluate(obj))
  end

  def test_registers_pass_through
    assert_equal "flags_obj", @scope.registers[:render_flags]
    @scope.registers[:foo] = "bar"
    assert_equal "bar", @ctx.registers[:foo]
    @scope.registers.static[:layout] = "alt"
    assert_equal "alt", @ctx.registers.static[:layout]
  end

  def test_handle_error
    @scope.template_name = "test.liquid"
    result = @scope.handle_error(StandardError.new("boom"), 5)
    assert_equal "boom", result
    assert_equal 1, @ctx.errors.length
  end

  def test_update_resource_limits
    @scope.update_resource_limits(render_score_limit: 1000)
    assert_equal 1000, @ctx.resource_limits.render_score_limit
  end

  def test_new_isolated_subcontext
    sub = @scope.new_isolated_subcontext
    assert_instance_of LiquidIL::Scope, sub
    refute_equal @scope.object_id, sub.object_id
    assert sub.context.is_a?(FakeContext)
  end

  def test_method_missing_delegates_storefront_methods
    assert_equal "flags_obj", @scope.render_flags
    assert @scope.respond_to?(:paginated_drop?)
    assert @scope.respond_to?(:render_flags)
    assert @scope.respond_to?(:shop)
    assert @scope.respond_to?(:theme)
  end

  def test_unknown_method_raises
    assert_raises(NoMethodError) { @scope.totally_nonexistent_method }
  end
end

# ════════════════════════════════════════════════════════════════════
# Scope works standalone (no liquid_context)
# ════════════════════════════════════════════════════════════════════

class ScopeStandaloneTest < Minitest::Test
  def test_basic_operations
    scope = LiquidIL::Scope.new({"x" => 1})
    assert_equal 1, scope.lookup("x")
    scope.assign("y", 2)
    assert_equal 2, scope.lookup("y")
    scope.push_scope
    scope.assign_local("z", 3)
    assert_equal 3, scope.lookup("z")
    scope.pop_scope
    assert_nil scope.lookup("z")
  end

  def test_context_is_nil
    assert_nil LiquidIL::Scope.new({}).context
  end

  def test_registers_returns_internal_hash
    regs = LiquidIL::Scope.new({}).registers
    assert_kind_of Hash, regs
  end

  def test_evaluate_standalone
    assert_equal "hello", LiquidIL::Scope.new({}).evaluate("hello")
  end

  def test_stack_standalone
    scope = LiquidIL::Scope.new({})
    scope.stack do
      scope["x"] = 1
      assert_equal 1, scope.lookup("x")
    end
    assert_nil scope.lookup("x")
  end

  def test_method_missing_raises
    assert_raises(NoMethodError) { LiquidIL::Scope.new({}).paginated_drop?("x") }
  end

  def test_handle_error_raises
    assert_raises(StandardError) { LiquidIL::Scope.new({}).handle_error(StandardError.new("boom")) }
  end
end
