# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "liquid/spec/cli/adapter_dsl"

class LiquidVmOptionalTest < Minitest::Test
  def test_optional_adapter_shim_skips_cleanly_when_private_checkout_is_absent
    assert_optional_adapter_skips("../spec/liquid_vm.rb", "LIQUID_VM_ADAPTER", "Shopify/liquid-vm is optional")
  end

  def test_optional_ssa_adapter_shim_skips_cleanly_when_private_checkout_is_absent
    assert_optional_adapter_skips("../spec/liquid_vm_ssa.rb", "LIQUID_VM_SSA_ADAPTER", "Shopify/liquid-vm SSA is optional")
  end

  def test_default_matrix_does_not_include_private_liquid_vm_adapter
    rakefile = File.read(File.expand_path("../Rakefile", __dir__))

    assert_includes rakefile, 'ENV["WITH_LIQUID_VM"] == "1"'
    assert_includes rakefile, "ADAPTER_VM_SSA"
    refute_match(/File\.exist\?\(ADAPTER_VM\)/, rakefile)
  end

  private

  def assert_optional_adapter_skips(adapter_path, adapter_env_key, message)
    Dir.mktmpdir("missing-liquid-vm") do |dir|
      with_env("LIQUID_VM_PATH" => File.join(dir, "liquid-vm"), adapter_env_key => nil) do
        LiquidSpec.reset!
        load File.expand_path(adapter_path, __dir__)

        assert LiquidSpec.compile_block, "shim should define a compile block even when skipped"
        assert LiquidSpec.render_block, "shim should define a render block even when skipped"

        error = assert_raises(LiquidSpec::SkipAdapter) { LiquidSpec.run_setup! }
        assert_includes error.message, message
      ensure
        LiquidSpec.reset!
      end
    end
  end


  def with_env(values)
    old = values.transform_values { nil }
    values.each_key { |key| old[key] = ENV[key] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
