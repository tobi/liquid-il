# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Test filter modules (scoped to avoid conflicts with extensibility_test.rb)
module GlobalTestFilters
  module Money
    def money(input, currency = "USD")
      "$#{"%.2f" % input.to_f} #{currency}"
    end
  end

  module Formatting
    def exclaim(input)
      "#{input}!"
    end

    def whisper(input)
      "(#{input})"
    end
  end

  module Override
    def money(input, _currency = nil)
      "OVERRIDDEN"
    end
  end
end

# ════════════════════════════════════════════════════════════
# Filters.register / Filters.global_registry
# ════════════════════════════════════════════════════════════

class FiltersGlobalRegistryTest < Minitest::Test
  def setup
    LiquidIL::Filters.clear_global_registry!
  end

  def teardown
    LiquidIL::Filters.clear_global_registry!
  end

  def test_register_adds_to_global_registry
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    assert LiquidIL::Filters.global_filter_registered?("money")
  end

  def test_register_multiple_methods_from_module
    LiquidIL::Filters.register(GlobalTestFilters::Formatting)
    assert LiquidIL::Filters.global_filter_registered?("exclaim")
    assert LiquidIL::Filters.global_filter_registered?("whisper")
  end

  def test_register_stores_module_and_method
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    entry = LiquidIL::Filters.global_registry["money"]
    assert_equal GlobalTestFilters::Money, entry[:module]
    assert_equal true, entry[:pure]
    assert_kind_of UnboundMethod, entry[:method]
  end

  def test_register_default_impure
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    assert_equal false, LiquidIL::Filters.global_registry["money"][:pure]
  end

  def test_register_requires_module
    assert_raises(ArgumentError) { LiquidIL::Filters.register("not a module") }
    assert_raises(ArgumentError) { LiquidIL::Filters.register(42) }
  end

  def test_clear_global_registry
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    assert LiquidIL::Filters.global_filter_registered?("money")
    LiquidIL::Filters.clear_global_registry!
    refute LiquidIL::Filters.global_filter_registered?("money")
  end

  def test_global_registry_starts_empty_after_clear
    LiquidIL::Filters.clear_global_registry!
    assert_empty LiquidIL::Filters.global_registry
  end

  def test_global_filter_registered_with_symbol
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    assert LiquidIL::Filters.global_filter_registered?(:money)
  end

  def test_unregistered_filter_not_found
    refute LiquidIL::Filters.global_filter_registered?("nonexistent")
  end
end

# ════════════════════════════════════════════════════════════
# LiquidIL.register_filter (top-level convenience)
# ════════════════════════════════════════════════════════════

class LiquidILRegisterFilterTest < Minitest::Test
  def setup
    LiquidIL::Filters.clear_global_registry!
  end

  def teardown
    LiquidIL::Filters.clear_global_registry!
  end

  def test_register_filter_delegates_to_filters
    LiquidIL.register_filter(GlobalTestFilters::Money, pure: true)
    assert LiquidIL::Filters.global_filter_registered?("money")
    assert_equal true, LiquidIL::Filters.global_registry["money"][:pure]
  end

  def test_register_filter_available_in_render
    LiquidIL.register_filter(GlobalTestFilters::Money)
    assert_equal "$42.00 USD", LiquidIL.render("{{ x | money }}", "x" => 42)
  end
end

# ════════════════════════════════════════════════════════════
# Context inherits global filters
# ════════════════════════════════════════════════════════════

class ContextInheritsGlobalFiltersTest < Minitest::Test
  def setup
    LiquidIL::Filters.clear_global_registry!
  end

  def teardown
    LiquidIL::Filters.clear_global_registry!
  end

  def test_new_context_inherits_global_filters
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    ctx = LiquidIL::Context.new
    assert ctx.custom_filters.key?("money")
  end

  def test_context_without_global_filters_has_empty_custom_filters
    ctx = LiquidIL::Context.new
    assert_empty ctx.custom_filters
  end

  def test_global_filter_usable_through_context
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    ctx = LiquidIL::Context.new
    assert_equal "$10.00 USD", ctx.render("{{ x | money }}", "x" => 10)
  end

  def test_global_filter_with_args_through_context
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    ctx = LiquidIL::Context.new
    assert_equal "$10.00 EUR", ctx.render('{{ x | money: "EUR" }}', "x" => 10)
  end

  def test_global_filter_chained_with_builtins
    LiquidIL::Filters.register(GlobalTestFilters::Formatting)
    ctx = LiquidIL::Context.new
    assert_equal "HELLO!", ctx.render("{{ x | upcase | exclaim }}", "x" => "hello")
  end

  def test_context_per_context_filter_overrides_global
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    ctx = LiquidIL::Context.new
    ctx.register_filter(GlobalTestFilters::Override, pure: true)
    assert_equal "OVERRIDDEN", ctx.render("{{ x | money }}", "x" => 42)
  end

  def test_global_filter_does_not_affect_preexisting_contexts
    ctx = LiquidIL::Context.new
    # Register AFTER context creation
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    # Pre-existing context doesn't have it (it was seeded at construction time)
    refute ctx.custom_filters.key?("money")
  end

  def test_multiple_contexts_get_independent_copies
    LiquidIL::Filters.register(GlobalTestFilters::Money)
    ctx1 = LiquidIL::Context.new
    ctx2 = LiquidIL::Context.new
    # Mutating one doesn't affect the other
    ctx1.register_filter(GlobalTestFilters::Formatting)
    assert ctx1.custom_filters.key?("exclaim")
    refute ctx2.custom_filters.key?("exclaim")
  end
end

# ════════════════════════════════════════════════════════════
# Global filters with from_cache templates
# ════════════════════════════════════════════════════════════

class GlobalFiltersWithCacheTest < Minitest::Test
  def setup
    LiquidIL::Filters.clear_global_registry!
  end

  def teardown
    LiquidIL::Filters.clear_global_registry!
  end

  def test_from_cache_template_uses_global_filters
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    t = LiquidIL.parse("{{ x | money }}")
    data = t.cache_data

    restored = LiquidIL::Template.from_cache(**data)
    assert_equal "$42.00 USD", restored.render("x" => 42)
  end

  def test_from_cache_template_without_global_filters
    # Compile with filter registered
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    t = LiquidIL.parse("{{ x | money }}")
    data = t.cache_data

    # Clear global filters before restoring
    LiquidIL::Filters.clear_global_registry!
    restored = LiquidIL::Template.from_cache(**data)
    # Without the filter, money is unknown — input passes through
    assert_equal "42", restored.render("x" => 42)
  end

  def test_from_cache_with_multiple_global_filters
    LiquidIL::Filters.register(GlobalTestFilters::Money, pure: true)
    LiquidIL::Filters.register(GlobalTestFilters::Formatting)

    t = LiquidIL.parse("{{ x | money | exclaim }}")
    restored = LiquidIL::Template.from_cache(**t.cache_data)
    assert_equal "$5.00 USD!", restored.render("x" => 5)
  end
end
