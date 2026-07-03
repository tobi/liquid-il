#!/usr/bin/env ruby
# frozen_string_literal: true

# Optional Shopify/liquid-vm adapter shim for liquid-spec.
#
# Shopify/liquid-vm is private, so this file must be safe to load without the
# repo or gem present. The rake tasks under `liquid_vm:*` clone/update the repo
# into /tmp/liquid-vm by default and point this shim at its real adapter.
#
# Manual usage:
#   LIQUID_VM_PATH=/tmp/liquid-vm bundle exec liquid-spec run spec/liquid_vm.rb
#   LIQUID_VM_ADAPTER=/tmp/liquid-vm/test/adapters/liquid_vm.rb bundle exec liquid-spec bench --adapter=spec/liquid_vm.rb --adapter=spec/liquid_il.rb

require "liquid/spec/cli/adapter_dsl"

repo_path = File.expand_path(ENV.fetch("LIQUID_VM_PATH", "/tmp/liquid-vm"))
backend = ENV["LIQUID_VM_BACKEND"] == "ssa" ? "liquid_vm_ssa.rb" : "liquid_vm.rb"
adapter_path = ENV["LIQUID_VM_ADAPTER"]
adapter_path = File.join(repo_path, "test", "adapters", backend) if adapter_path.nil? || adapter_path.empty?
adapter_path = File.expand_path(adapter_path)

if File.file?(adapter_path)
  ENV["LIQUID_VM_PATH"] ||= repo_path
  ENV["LIQUID_VM_ADAPTER"] ||= adapter_path
  load adapter_path
else
  LiquidSpec.setup do |_ctx|
    LiquidSpec.skip!(<<~MSG.chomp)
      Shopify/liquid-vm is optional and was not found.
      Run `bundle exec rake liquid_vm:setup` to clone it into /tmp/liquid-vm,
      or set LIQUID_VM_PATH=/path/to/liquid-vm / LIQUID_VM_ADAPTER=/path/to/adapter.rb.
    MSG
  end

  LiquidSpec.configure do |config|
    config.missing_features = []
  end

  LiquidSpec.compile do |_ctx, _source, _compile_options|
    raise "liquid-vm adapter is unavailable"
  end

  LiquidSpec.render do |_ctx, _assigns, _render_options|
    raise "liquid-vm adapter is unavailable"
  end
end
