# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# ── Test Drops ──────────────────────────────────────────────

class VictimDrop < LiquidIL::Drop
  def initialize(name = "Widget", secret = "TOP_SECRET_API_KEY")
    super()
    @name = name
    @secret = secret
    @internal_state = { db_password: "hunter2" }
  end

  def name
    @name
  end

  def price
    42
  end
end

class EnumerableDrop < LiquidIL::Drop
  include Enumerable

  def initialize(items)
    super()
    @items = items
  end

  def each(&block)
    @items.each(&block)
  end

  def title
    "my list"
  end
end

class NestedDrop < LiquidIL::Drop
  def initialize
    super()
  end

  def child
    VictimDrop.new("nested_child", "child_secret")
  end

  def items
    [VictimDrop.new("a"), VictimDrop.new("b")]
  end
end

# Object with a dangerous [] that calls send
class UnsafeHashLikeObject
  def [](key)
    send(key) rescue nil
  end

  def secret
    "LEAKED_VIA_BRACKET"
  end

  def name
    "unsafe"
  end
end

# Object that exposes everything publicly
class WideOpenObject
  def name; "wide_open"; end
  def secret; "TOP_SECRET"; end
  def system_call; "pwned"; end
  def eval_result; "evaled"; end
end

# Object with to_liquid returning a safe hash
class SafeProxyObject
  def to_liquid
    { "name" => "proxied", "safe" => true }
  end

  def secret
    "NEVER_SEE_THIS"
  end
end

# Object with to_liquid returning self (pretending to be a drop without invoke_drop)
class FakeDropObject
  def to_liquid
    self
  end

  def name
    "fake_drop"
  end

  def secret
    "FAKE_SECRET"
  end
end

# ── Helpers ─────────────────────────────────────────────────

module SecurityTestHelper
  def render(source, assigns = {})
    LiquidIL::Template.parse(source).render(assigns)
  end

  # Assert that the template output is empty (method blocked)
  def assert_blocked(source, assigns, msg = nil)
    result = render(source, assigns).strip
    assert_equal "", result, msg || "Expected #{source.inspect} to be blocked but got #{result.inspect}"
  end

  # Assert that the template output does NOT contain the secret
  def assert_no_leak(source, assigns, secret, msg = nil)
    result = render(source, assigns)
    refute_includes result, secret, msg || "Secret leaked in #{source.inspect}: #{result.inspect}"
  end
end

# ════════════════════════════════════════════════════════════
# 1. DANGEROUS OBJECT/KERNEL METHODS ON DROPS
# ════════════════════════════════════════════════════════════

class DropBlocksDangerousMethodsTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new
    @assigns = { "d" => @drop }
  end

  # -- Reflection --

  def test_blocks_class
    assert_blocked '{{ d.class }}', @assigns
  end

  def test_blocks_object_id
    assert_blocked '{{ d.object_id }}', @assigns
  end

  def test_blocks_inspect
    assert_blocked '{{ d.inspect }}', @assigns
  end

  def test_blocks_to_s
    assert_blocked '{{ d.to_s }}', @assigns
  end

  def test_blocks_hash
    assert_blocked '{{ d.hash }}', @assigns
  end

  def test_blocks_methods
    assert_blocked '{{ d.methods }}', @assigns
  end

  def test_blocks_public_methods
    assert_blocked '{{ d.public_methods }}', @assigns
  end

  def test_blocks_private_methods
    assert_blocked '{{ d.private_methods }}', @assigns
  end

  def test_blocks_protected_methods
    assert_blocked '{{ d.protected_methods }}', @assigns
  end

  def test_blocks_singleton_methods
    assert_blocked '{{ d.singleton_methods }}', @assigns
  end

  def test_blocks_singleton_class
    assert_blocked '{{ d.singleton_class }}', @assigns
  end

  def test_blocks_respond_to
    assert_blocked '{{ d.respond_to? }}', @assigns
  end

  def test_blocks_is_a
    assert_blocked '{{ d.is_a? }}', @assigns
  end

  def test_blocks_kind_of
    assert_blocked '{{ d.kind_of? }}', @assigns
  end

  def test_blocks_instance_of
    assert_blocked '{{ d.instance_of? }}', @assigns
  end

  def test_blocks_nil_question
    assert_blocked '{{ d.nil? }}', @assigns
  end

  def test_blocks_frozen_question
    assert_blocked '{{ d.frozen? }}', @assigns
  end

  def test_blocks_equal_question
    assert_blocked '{{ d.equal? }}', @assigns
  end

  def test_blocks_eql_question
    assert_blocked '{{ d.eql? }}', @assigns
  end

  # -- Message sending / eval --

  def test_blocks_send
    assert_blocked '{{ d.send }}', @assigns
  end

  def test_blocks___send__
    assert_blocked '{{ d.__send__ }}', @assigns
  end

  def test_blocks_public_send
    assert_blocked '{{ d.public_send }}', @assigns
  end

  def test_blocks_instance_eval
    assert_blocked '{{ d.instance_eval }}', @assigns
  end

  def test_blocks_instance_exec
    assert_blocked '{{ d.instance_exec }}', @assigns
  end

  def test_blocks_method
    assert_blocked '{{ d.method }}', @assigns
  end

  def test_blocks_public_method
    assert_blocked '{{ d.public_method }}', @assigns
  end

  def test_blocks_singleton_method
    assert_blocked '{{ d.singleton_method }}', @assigns
  end

  # -- Instance variable access --

  def test_blocks_instance_variable_get
    assert_blocked '{{ d.instance_variable_get }}', @assigns
  end

  def test_blocks_instance_variable_set
    assert_blocked '{{ d.instance_variable_set }}', @assigns
  end

  def test_blocks_instance_variable_defined
    assert_blocked '{{ d.instance_variable_defined? }}', @assigns
  end

  def test_blocks_instance_variables
    assert_blocked '{{ d.instance_variables }}', @assigns
  end

  def test_blocks_remove_instance_variable
    assert_blocked '{{ d.remove_instance_variable }}', @assigns
  end

  # -- Mutation --

  def test_blocks_freeze
    assert_blocked '{{ d.freeze }}', @assigns
  end

  def test_blocks_clone
    assert_blocked '{{ d.clone }}', @assigns
  end

  def test_blocks_dup
    assert_blocked '{{ d.dup }}', @assigns
  end

  def test_blocks_extend
    assert_blocked '{{ d.extend }}', @assigns
  end

  def test_blocks_define_singleton_method
    assert_blocked '{{ d.define_singleton_method }}', @assigns
  end

  # -- Functional --

  def test_blocks_tap
    assert_blocked '{{ d.tap }}', @assigns
  end

  def test_blocks_then
    assert_blocked '{{ d.then }}', @assigns
  end

  def test_blocks_yield_self
    assert_blocked '{{ d.yield_self }}', @assigns
  end

  # -- Enumeration --

  def test_blocks_enum_for
    assert_blocked '{{ d.enum_for }}', @assigns
  end

  def test_blocks_to_enum
    assert_blocked '{{ d.to_enum }}', @assigns
  end

  # -- Display / IO --

  def test_blocks_display
    assert_blocked '{{ d.display }}', @assigns
  end
end

# ════════════════════════════════════════════════════════════
# 2. BRACKET ACCESS ATTACKS
# ════════════════════════════════════════════════════════════

class BracketAccessSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new
    @assigns = { "d" => @drop }
  end

  def test_bracket_blocks_class
    assert_blocked '{% assign k = "class" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_send
    assert_blocked '{% assign k = "send" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks___send__
    assert_blocked '{% assign k = "__send__" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_instance_eval
    assert_blocked '{% assign k = "instance_eval" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_instance_variable_get
    assert_blocked '{% assign k = "instance_variable_get" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_instance_variables
    assert_blocked '{% assign k = "instance_variables" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_object_id
    assert_blocked '{% assign k = "object_id" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_methods
    assert_blocked '{% assign k = "methods" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_public_send
    assert_blocked '{% assign k = "public_send" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_method
    assert_blocked '{% assign k = "method" %}{{ d[k] }}', @assigns
  end

  def test_bracket_blocks_singleton_class
    assert_blocked '{% assign k = "singleton_class" %}{{ d[k] }}', @assigns
  end

  def test_bracket_allows_whitelisted
    result = render('{% assign k = "name" %}{{ d[k] }}', @assigns)
    assert_equal "Widget", result.strip
  end
end

# ════════════════════════════════════════════════════════════
# 3. SECRET / IVAR LEAK PREVENTION
# ════════════════════════════════════════════════════════════

class SecretLeakPreventionTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new("Widget", "TOP_SECRET_API_KEY")
    @assigns = { "d" => @drop }
    @secret = "TOP_SECRET_API_KEY"
  end

  # The @secret ivar is not exposed as a method — should never appear
  def test_no_leak_via_dot_access
    assert_no_leak '{{ d.secret }}', @assigns, @secret
  end

  def test_no_leak_via_bracket_access
    assert_no_leak '{% assign k = "secret" %}{{ d[k] }}', @assigns, @secret
  end

  def test_no_leak_via_instance_variables
    assert_no_leak '{{ d.instance_variables }}', @assigns, @secret
  end

  def test_no_leak_via_instance_variable_get
    assert_no_leak '{{ d.instance_variable_get }}', @assigns, @secret
  end

  def test_no_leak_via_inspect
    assert_no_leak '{{ d.inspect }}', @assigns, @secret
  end

  def test_no_leak_via_to_s
    assert_no_leak '{{ d.to_s }}', @assigns, @secret
  end

  def test_no_leak_via_methods_iteration
    assert_no_leak '{% for m in d.methods %}{{ m }}{% endfor %}', @assigns, @secret
  end

  def test_no_leak_via_class_name
    assert_no_leak '{{ d.class }}', @assigns, "VictimDrop"
  end

  def test_no_leak_internal_state_hash
    assert_no_leak '{{ d.internal_state }}', @assigns, "hunter2"
    assert_no_leak '{{ d.internal_state }}', @assigns, "db_password"
  end
end

# ════════════════════════════════════════════════════════════
# 4. PROPERTY CHAIN ATTACKS
# ════════════════════════════════════════════════════════════

class PropertyChainSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @nested = NestedDrop.new
    @assigns = { "d" => @nested }
  end

  def test_nested_drop_allows_safe_methods
    assert_equal "nested_child", render("{{ d.child.name }}", @assigns)
  end

  def test_nested_drop_blocks_class
    assert_blocked '{{ d.child.class }}', @assigns
  end

  def test_nested_drop_blocks_send
    assert_blocked '{{ d.child.send }}', @assigns
  end

  def test_nested_drop_blocks_instance_eval
    assert_blocked '{{ d.child.instance_eval }}', @assigns
  end

  def test_nested_drop_blocks_object_id
    assert_blocked '{{ d.child.object_id }}', @assigns
  end

  def test_chain_through_array_blocks_class
    # d.items returns array of drops, items.class => array[0] (not Class)
    # The key point: it should NOT return the string "Array"
    result = render('{{ d.items.class }}', @assigns)
    refute_includes result, "Array"
  end

  def test_chain_safe_method_then_string_method
    # d.child.name => "nested_child", then .size => 12
    assert_equal "12", render('{{ d.child.name.size }}', @assigns).strip
  end

  def test_deep_chain_attack
    assert_blocked '{{ d.child.name.class }}', @assigns
  end

  def test_string_result_class_blocked
    # "Widget".class should not be accessible
    result = render('{{ d.child.name.class }}', @assigns)
    refute_includes result, "String"
  end
end

# ════════════════════════════════════════════════════════════
# 5. CONDITIONAL / LOOP PROBING
# ════════════════════════════════════════════════════════════

class ConditionalProbingSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new
    @assigns = { "d" => @drop }
  end

  def test_if_class_is_falsy
    assert_blocked '{% if d.class %}LEAKED{% endif %}', @assigns
  end

  def test_if_send_is_falsy
    assert_blocked '{% if d.send %}LEAKED{% endif %}', @assigns
  end

  def test_if_respond_to_is_falsy
    assert_blocked '{% if d.respond_to? %}LEAKED{% endif %}', @assigns
  end

  def test_if_methods_is_falsy
    assert_blocked '{% if d.methods %}LEAKED{% endif %}', @assigns
  end

  def test_if_instance_variables_is_falsy
    assert_blocked '{% if d.instance_variables %}LEAKED{% endif %}', @assigns
  end

  def test_for_over_methods_yields_nothing
    assert_blocked '{% for m in d.methods %}{{ m }}{% endfor %}', @assigns
  end

  def test_for_over_instance_variables_yields_nothing
    assert_blocked '{% for v in d.instance_variables %}{{ v }}{% endfor %}', @assigns
  end

  def test_class_equality_is_false
    assert_blocked '{% if d.class == "VictimDrop" %}LEAKED{% endif %}', @assigns
  end

  def test_methods_contains_is_false
    assert_blocked '{% if d.methods contains "name" %}LEAKED{% endif %}', @assigns
  end

  def test_methods_size_is_zero
    assert_equal "0", render('{{ d.methods | size }}', @assigns).strip
  end

  def test_instance_variables_size_is_zero
    assert_equal "0", render('{{ d.instance_variables | size }}', @assigns).strip
  end
end

# ════════════════════════════════════════════════════════════
# 6. ASSIGN / CAPTURE EXTRACTION
# ════════════════════════════════════════════════════════════

class AssignCaptureSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new("Widget", "TOP_SECRET")
    @assigns = { "d" => @drop }
  end

  def test_assign_class_is_nil
    assert_blocked '{% assign c = d.class %}{{ c }}', @assigns
  end

  def test_assign_send_is_nil
    assert_blocked '{% assign s = d.send %}{{ s }}', @assigns
  end

  def test_assign_instance_eval_is_nil
    assert_blocked '{% assign e = d.instance_eval %}{{ e }}', @assigns
  end

  def test_assign_object_id_is_nil
    assert_blocked '{% assign o = d.object_id %}{{ o }}', @assigns
  end

  def test_capture_class_is_empty
    result = render('{% capture c %}{{ d.class }}{% endcapture %}[{{ c }}]', @assigns)
    assert_equal "[]", result.strip
  end

  def test_capture_methods_is_empty
    result = render('{% capture m %}{{ d.methods }}{% endcapture %}[{{ m }}]', @assigns)
    assert_equal "[]", result.strip
  end

  def test_map_class_from_drop_array
    nested = NestedDrop.new
    result = render('{{ d.items | map: "class" }}', "d" => nested)
    refute_includes result, "VictimDrop"
  end

  def test_map_name_from_drop_array
    nested = NestedDrop.new
    result = render('{{ d.items | map: "name" | join: "," }}', "d" => nested)
    assert_equal "a,b", result.strip
  end
end

# ════════════════════════════════════════════════════════════
# 7. FILTER CHAIN ATTACKS ON DROPS
# ════════════════════════════════════════════════════════════

class FilterChainSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = VictimDrop.new("Widget", "TOP_SECRET")
    @assigns = { "d" => @drop }
  end

  # json filter is not built-in — provided by host app (e.g., storefront)
  # def test_json_filter_does_not_leak_internals
  #   result = render('{{ d | json }}', @assigns)
  #   refute_includes result, "TOP_SECRET"
  #   refute_includes result, "secret"
  #   refute_includes result, "internal_state"
  #   refute_includes result, "hunter2"
  # end

  def test_size_filter_on_drop
    # size filter on a drop output — should be size of to_s, not method count
    result = render('{{ d | size }}', @assigns).strip
    refute_equal "", result  # Some numeric value is fine
  end

  def test_default_filter_on_blocked_property
    # d.class returns nil → default should kick in
    assert_equal "fallback", render('{{ d.class | default: "fallback" }}', @assigns).strip
  end

  def test_default_filter_on_allowed_property
    assert_equal "Widget", render('{{ d.name | default: "fallback" }}', @assigns).strip
  end

  def test_upcase_on_allowed_property
    assert_equal "WIDGET", render('{{ d.name | upcase }}', @assigns).strip
  end

  def test_upcase_on_blocked_property
    assert_blocked '{{ d.class | upcase }}', @assigns
  end

  def test_append_on_blocked_property
    # d.class returns nil, append coerces nil to "" → "suffix"
    # The key: the class name "VictimDrop" must NOT appear
    result = render('{{ d.class | append: "suffix" }}', @assigns)
    refute_includes result, "VictimDrop"
  end
end

# ════════════════════════════════════════════════════════════
# 8. NON-DROP OBJECT SAFETY
# ════════════════════════════════════════════════════════════

class NonDropObjectSecurityTest < Minitest::Test
  include SecurityTestHelper

  # -- UnsafeHashLikeObject: has [] that calls send --

  def test_unsafe_hash_like_blocks_all_properties
    obj = UnsafeHashLikeObject.new
    assert_blocked '{{ o.name }}', "o" => obj
    assert_blocked '{{ o.secret }}', "o" => obj
    assert_blocked '{{ o.class }}', "o" => obj
    assert_blocked '{{ o.send }}', "o" => obj
    assert_blocked '{{ o.instance_eval }}', "o" => obj
  end

  # -- WideOpenObject: everything public, no Drop --

  def test_wide_open_object_blocks_all
    obj = WideOpenObject.new
    assert_blocked '{{ o.name }}', "o" => obj
    assert_blocked '{{ o.secret }}', "o" => obj
    assert_blocked '{{ o.system_call }}', "o" => obj
    assert_blocked '{{ o.class }}', "o" => obj
    assert_blocked '{{ o.send }}', "o" => obj
  end

  # -- SafeProxyObject: to_liquid returns hash --

  def test_safe_proxy_exposes_hash_keys
    obj = SafeProxyObject.new
    assert_equal "proxied", render('{{ o.name }}', "o" => obj)
  end

  def test_safe_proxy_blocks_non_hash_keys
    obj = SafeProxyObject.new
    assert_blocked '{{ o.secret }}', "o" => obj
    assert_blocked '{{ o.class }}', "o" => obj
    assert_blocked '{{ o.send }}', "o" => obj
  end

  # -- FakeDropObject: to_liquid returns self but no invoke_drop --

  def test_fake_drop_without_invoke_drop_blocks_all
    obj = FakeDropObject.new
    assert_blocked '{{ o.name }}', "o" => obj
    assert_blocked '{{ o.secret }}', "o" => obj
    assert_blocked '{{ o.class }}', "o" => obj
  end

  # -- BasicObject / Object.new --

  def test_plain_object_blocks_everything
    obj = Object.new
    assert_blocked '{{ o.class }}', "o" => obj
    assert_blocked '{{ o.object_id }}', "o" => obj
    assert_blocked '{{ o.send }}', "o" => obj
    assert_blocked '{{ o.instance_eval }}', "o" => obj
  end

  # -- Proc / Lambda / Method objects --

  def test_proc_not_callable_from_template
    assigns = { "f" => -> { "pwned" } }
    assert_blocked '{{ f.call }}', assigns
    assert_blocked '{{ f.class }}', assigns
  end

  def test_method_object_not_callable
    assigns = { "m" => method(:puts) }
    assert_blocked '{{ m.call }}', assigns
    assert_blocked '{{ m.class }}', assigns
  end
end

# ════════════════════════════════════════════════════════════
# 9. SAFE TYPES (Hash, Array, String, Integer, etc.)
# ════════════════════════════════════════════════════════════

class SafeTypesTest < Minitest::Test
  include SecurityTestHelper

  # -- Hash --

  def test_hash_allows_key_access
    assert_equal "test", render('{{ h.name }}', "h" => { "name" => "test" })
  end

  def test_hash_allows_size
    assert_equal "2", render('{{ h.size }}', "h" => { "a" => 1, "b" => 2 }).strip
  end

  def test_hash_key_named_class_returns_value_not_class
    # Hash with a key "class" should return the hash value
    assert_equal "my_class", render('{{ h.class }}', "h" => { "class" => "my_class" })
  end

  def test_hash_does_not_leak_actual_class
    # Hash without a "class" key — should return nil (not "Hash")
    result = render('{{ h.class }}', "h" => { "a" => 1 })
    refute_includes result, "Hash"
  end

  # -- Array --

  def test_array_allows_size
    assert_equal "3", render('{{ a.size }}', "a" => [1, 2, 3]).strip
  end

  def test_array_allows_first
    assert_equal "1", render('{{ a.first }}', "a" => [1, 2, 3]).strip
  end

  def test_array_allows_last
    assert_equal "3", render('{{ a.last }}', "a" => [1, 2, 3]).strip
  end

  # -- String --

  def test_string_allows_size
    assert_equal "5", render('{{ s.size }}', "s" => "hello").strip
  end

  def test_string_allows_first
    assert_equal "h", render('{{ s.first }}', "s" => "hello").strip
  end

  def test_string_allows_last
    assert_equal "o", render('{{ s.last }}', "s" => "hello").strip
  end

  def test_string_class_not_accessible
    result = render('{{ s.class }}', "s" => "hello")
    refute_includes result, "String"
  end

  # -- Integer --

  def test_integer_allows_size
    # Integer#size returns byte size (8 on 64-bit), not digit count
    result = render('{{ n.size }}', "n" => 1234).strip
    assert_match(/\A\d+\z/, result)
  end
end

# ════════════════════════════════════════════════════════════
# 10. LIQUID::DROP COMPATIBILITY
# ════════════════════════════════════════════════════════════

class LiquidDropCompatSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    require "liquid"

    @klass = Class.new(Liquid::Drop) do
      def initialize(name)
        super()
        @name = name
        @secret = "liquid_drop_secret"
      end

      def name
        @name
      end

      def price
        99
      end
    end
  end

  def test_liquid_drop_allows_defined_methods
    drop = @klass.new("Gadget")
    assert_equal "Gadget", render('{{ d.name }}', "d" => drop)
    assert_equal "99", render('{{ d.price }}', "d" => drop)
  end

  def test_liquid_drop_blocks_class
    assert_blocked '{{ d.class }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_send
    assert_blocked '{{ d.send }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks___send__
    assert_blocked '{{ d.__send__ }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_instance_eval
    assert_blocked '{{ d.instance_eval }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_instance_variable_get
    assert_blocked '{{ d.instance_variable_get }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_object_id
    assert_blocked '{{ d.object_id }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_methods
    assert_blocked '{{ d.methods }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_respond_to
    assert_blocked '{{ d.respond_to? }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_blocks_inspect
    assert_blocked '{{ d.inspect }}', "d" => @klass.new("x")
  end

  def test_liquid_drop_does_not_leak_secret_ivar
    drop = @klass.new("x")
    assert_no_leak '{{ d.secret }}', { "d" => drop }, "liquid_drop_secret"
    assert_no_leak '{{ d.inspect }}', { "d" => drop }, "liquid_drop_secret"
  end

  def test_liquid_drop_bracket_access_safe
    drop = @klass.new("Gadget")
    assert_equal "Gadget", render('{% assign k = "name" %}{{ d[k] }}', "d" => drop)
    assert_blocked '{% assign k = "class" %}{{ d[k] }}', "d" => drop
    assert_blocked '{% assign k = "send" %}{{ d[k] }}', "d" => drop
  end
end

# ════════════════════════════════════════════════════════════
# 11. to_liquid PROTOCOL
# ════════════════════════════════════════════════════════════

class ToLiquidProtocolTest < Minitest::Test
  include SecurityTestHelper

  def test_to_liquid_hash_exposes_keys
    obj = Object.new
    def obj.to_liquid; { "name" => "from_to_liquid", "status" => "ok" }; end
    assert_equal "from_to_liquid", render('{{ o.name }}', "o" => obj)
    assert_equal "ok", render('{{ o.status }}', "o" => obj)
  end

  def test_to_liquid_hash_does_not_expose_object_methods
    obj = Object.new
    def obj.to_liquid; { "name" => "safe" }; end
    assert_blocked '{{ o.class }}', "o" => obj
    assert_blocked '{{ o.send }}', "o" => obj
    assert_blocked '{{ o.instance_eval }}', "o" => obj
  end

  def test_to_liquid_returning_string
    obj = Object.new
    def obj.to_liquid; "i_am_a_string"; end
    assert_equal "13", render('{{ o.size }}', "o" => obj).strip
  end

  def test_to_liquid_returning_array
    obj = Object.new
    def obj.to_liquid; [10, 20, 30]; end
    assert_equal "3", render('{{ o.size }}', "o" => obj).strip
    assert_equal "10", render('{{ o.first }}', "o" => obj).strip
  end

  def test_to_liquid_returning_nil_blocks_all
    obj = Object.new
    def obj.to_liquid; nil; end
    assert_blocked '{{ o.name }}', "o" => obj
    assert_blocked '{{ o.class }}', "o" => obj
  end

  def test_drop_to_liquid_returns_self
    drop = VictimDrop.new
    assert_equal drop, drop.to_liquid
  end

  def test_hash_accessible_without_to_liquid
    assert_equal "1", render('{{ h.x }}', "h" => { "x" => 1 })
  end

  def test_string_accessible_without_to_liquid
    assert_equal "5", render('{{ s.size }}', "s" => "hello").strip
  end

  def test_array_accessible_without_to_liquid
    assert_equal "3", render('{{ a.size }}', "a" => [1, 2, 3]).strip
  end
end

# ════════════════════════════════════════════════════════════
# 12. ENUMERABLE DROP SECURITY
# ════════════════════════════════════════════════════════════

class EnumerableDropSecurityTest < Minitest::Test
  include SecurityTestHelper

  def setup
    @drop = EnumerableDrop.new([1, 2, 3])
    @assigns = { "d" => @drop }
  end

  def test_allows_subclass_methods
    assert_equal "my list", render('{{ d.title }}', @assigns)
  end

  def test_blocks_class
    assert_blocked '{{ d.class }}', @assigns
  end

  def test_blocks_send
    assert_blocked '{{ d.send }}', @assigns
  end

  def test_blocks_instance_eval
    assert_blocked '{{ d.instance_eval }}', @assigns
  end

  def test_blocks_object_id
    assert_blocked '{{ d.object_id }}', @assigns
  end

  def test_blocks_methods
    assert_blocked '{{ d.methods }}', @assigns
  end

  def test_blocks_private_methods
    assert_blocked '{{ d.private_methods }}', @assigns
  end

  # Enumerable methods that Liquid allows
  def test_invokable_methods_includes_to_liquid
    assert_includes EnumerableDrop.invokable_methods, "to_liquid"
  end

  def test_invokable_methods_includes_title
    assert_includes EnumerableDrop.invokable_methods, "title"
  end

  def test_invokable_methods_excludes_class
    refute_includes EnumerableDrop.invokable_methods, "class"
  end

  def test_invokable_methods_excludes_send
    refute_includes EnumerableDrop.invokable_methods, "send"
  end

  def test_invokable_methods_excludes_each
    # each is explicitly blacklisted even though it's defined
    refute_includes EnumerableDrop.invokable_methods, "each"
  end
end

# ════════════════════════════════════════════════════════════
# 13. WHITELIST CORRECTNESS
# ════════════════════════════════════════════════════════════

class WhitelistCorrectnessTest < Minitest::Test
  def test_only_subclass_methods_are_invokable
    expected = Set.new(%w[name price to_liquid])
    assert_equal expected, VictimDrop.invokable_methods
  end

  def test_drop_base_class_has_only_to_liquid
    assert_equal Set.new(["to_liquid"]), LiquidIL::Drop.invokable_methods
  end

  def test_invokable_is_false_for_object_methods
    Object.instance_methods.each do |m|
      next if m == :to_liquid  # to_liquid is always allowed
      refute VictimDrop.invokable?(m.to_s),
        "#{m} should NOT be invokable on VictimDrop"
    end
  end

  def test_invokable_is_true_for_subclass_methods
    assert VictimDrop.invokable?("name")
    assert VictimDrop.invokable?("price")
  end

  def test_invokable_caches_result
    # Second call should return the same Set object
    a = VictimDrop.invokable_methods
    b = VictimDrop.invokable_methods
    assert_same a, b
  end
end
