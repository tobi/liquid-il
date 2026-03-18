# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# === Drop Security ===

class SecurityDrop < LiquidIL::Drop
  def initialize(name, secret)
    super()
    @name = name
    @secret = secret
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

class DropSecurityTest < Minitest::Test
  def render(source, assigns = {})
    LiquidIL::Template.parse(source).render(assigns)
  end

  # --- Whitelisted methods work ---

  def test_drop_allows_defined_methods
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "Widget", render("{{ p.name }}", "p" => drop)
  end

  def test_drop_allows_multiple_defined_methods
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "Widget 42", render("{{ p.name }} {{ p.price }}", "p" => drop)
  end

  def test_drop_invokable_methods_only_has_subclass_methods
    methods = SecurityDrop.invokable_methods
    assert_includes methods, "name"
    assert_includes methods, "price"
    assert_includes methods, "to_liquid"
    refute_includes methods, "class"
    refute_includes methods, "send"
    refute_includes methods, "object_id"
  end

  # --- Dangerous Object methods are blocked ---

  def test_drop_blocks_class
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.class }}", "p" => drop).strip
  end

  def test_drop_blocks_send
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.send }}", "p" => drop).strip
  end

  def test_drop_blocks___send__
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.__send__ }}", "p" => drop).strip
  end

  def test_drop_blocks_public_send
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.public_send }}", "p" => drop).strip
  end

  def test_drop_blocks_object_id
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.object_id }}", "p" => drop).strip
  end

  def test_drop_blocks_instance_eval
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.instance_eval }}", "p" => drop).strip
  end

  def test_drop_blocks_instance_exec
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.instance_exec }}", "p" => drop).strip
  end

  def test_drop_blocks_instance_variable_get
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.instance_variable_get }}", "p" => drop).strip
  end

  def test_drop_blocks_instance_variable_set
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.instance_variable_set }}", "p" => drop).strip
  end

  def test_drop_blocks_methods
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.methods }}", "p" => drop).strip
  end

  def test_drop_blocks_private_methods
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.private_methods }}", "p" => drop).strip
  end

  def test_drop_blocks_inspect
    drop = SecurityDrop.new("Widget", "s3cr3t")
    # inspect is blocked for drops (not in whitelist)
    assert_equal "", render("{{ p.inspect }}", "p" => drop).strip
  end

  def test_drop_blocks_respond_to
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.respond_to? }}", "p" => drop).strip
  end

  def test_drop_blocks_freeze
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.freeze }}", "p" => drop).strip
  end

  def test_drop_blocks_dup
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.dup }}", "p" => drop).strip
  end

  def test_drop_blocks_clone
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.clone }}", "p" => drop).strip
  end

  def test_drop_blocks_extend
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.extend }}", "p" => drop).strip
  end

  def test_drop_blocks_define_singleton_method
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.define_singleton_method }}", "p" => drop).strip
  end

  # --- Instance variables not accessible ---

  def test_drop_cannot_read_ivar_via_name
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render("{{ p.secret }}", "p" => drop).strip
  end

  # --- Enumerable drops ---

  def test_enumerable_drop_allows_subclass_methods
    drop = EnumerableDrop.new([1, 2, 3])
    assert_equal "my list", render("{{ d.title }}", "d" => drop)
  end

  def test_enumerable_drop_blocks_dangerous_methods
    drop = EnumerableDrop.new([1, 2, 3])
    assert_equal "", render("{{ d.class }}", "d" => drop).strip
    assert_equal "", render("{{ d.send }}", "d" => drop).strip
    assert_equal "", render("{{ d.instance_eval }}", "d" => drop).strip
  end

  # --- Nested drop access ---

  def test_nested_drop_access_is_safe
    inner = SecurityDrop.new("Inner", "s3cr3t")
    outer = { "child" => inner }
    assert_equal "Inner", render("{{ p.child.name }}", "p" => outer)
    assert_equal "", render("{{ p.child.class }}", "p" => outer).strip
  end

  # --- Non-drop objects ---

  def test_plain_object_without_to_liquid_returns_nil
    obj = Object.new
    assert_equal "", render("{{ o.class }}", "o" => obj).strip
    assert_equal "", render("{{ o.object_id }}", "o" => obj).strip
  end

  def test_plain_hash_is_safe
    h = { "name" => "test", "class" => "blocked?" }
    # Hash with "class" key should return the hash value, not call .class
    assert_equal "test", render("{{ h.name }}", "h" => h)
    assert_equal "blocked?", render("{{ h.class }}", "h" => h)
  end

  def test_array_is_safe
    arr = [1, 2, 3]
    assert_equal "3", render("{{ a.size }}", "a" => arr)
    assert_equal "1", render("{{ a.first }}", "a" => arr)
    # Arrays don't expose .class — "class" is treated as integer index 0
    # This matches Liquid behavior: arr["class".to_i] = arr[0]
  end

  # --- Bracket access ---

  def test_drop_bracket_access_uses_invoke_drop
    drop = SecurityDrop.new("Widget", "s3cr3t")
    # This tests the bracket_lookup path
    assert_equal "Widget", render('{% assign key = "name" %}{{ p[key] }}', "p" => drop)
  end

  def test_drop_bracket_access_blocks_dangerous
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal "", render('{% assign key = "class" %}{{ p[key] }}', "p" => drop).strip
    assert_equal "", render('{% assign key = "send" %}{{ p[key] }}', "p" => drop).strip
  end
end

# === Liquid::Drop Compatibility ===

class LiquidDropCompatTest < Minitest::Test
  def render(source, assigns = {})
    LiquidIL::Template.parse(source).render(assigns)
  end

  def setup
    require "liquid"
  end

  def test_liquid_drop_works_in_liquid_il
    klass = Class.new(Liquid::Drop) do
      def initialize(name)
        super()
        @name = name
      end
      def name; @name; end
      def price; 99; end
    end

    drop = klass.new("Gadget")
    assert_equal "Gadget", render("{{ p.name }}", "p" => drop)
    assert_equal "99", render("{{ p.price }}", "p" => drop)
  end

  def test_liquid_drop_blocks_dangerous_methods
    klass = Class.new(Liquid::Drop) do
      def name; "safe"; end
    end

    drop = klass.new
    assert_equal "", render("{{ p.class }}", "p" => drop).strip
    assert_equal "", render("{{ p.send }}", "p" => drop).strip
    assert_equal "", render("{{ p.instance_eval }}", "p" => drop).strip
    assert_equal "", render("{{ p.object_id }}", "p" => drop).strip
  end

  def test_liquid_drop_to_liquid
    klass = Class.new(Liquid::Drop) do
      def name; "test"; end
    end
    drop = klass.new
    assert_equal drop, drop.to_liquid
  end
end

# === to_liquid Protocol ===

class ToLiquidProtocolTest < Minitest::Test
  def render(source, assigns = {})
    LiquidIL::Template.parse(source).render(assigns)
  end

  def test_to_liquid_called_on_variable_values
    obj = Object.new
    def obj.to_liquid; { "name" => "from_to_liquid" }; end
    assert_equal "from_to_liquid", render("{{ o.name }}", "o" => obj)
  end

  def test_to_liquid_returns_self_for_drops
    drop = SecurityDrop.new("Widget", "s3cr3t")
    assert_equal drop, drop.to_liquid
  end

  def test_hash_accessible_without_to_liquid
    # Hashes don't need to_liquid — they're natively safe
    h = { "x" => 1 }
    assert_equal "1", render("{{ h.x }}", "h" => h)
  end

  def test_string_accessible_without_to_liquid
    # Strings are natively safe
    assert_equal "5", render("{{ s.size }}", "s" => "hello")
  end

  def test_array_accessible_without_to_liquid
    # Arrays are natively safe
    assert_equal "3", render("{{ a.size }}", "a" => [1, 2, 3])
  end
end
