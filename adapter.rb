# frozen_string_literal: true

# Liquid Spec Adapter for LiquidIL
#
# Tests LiquidIL against the official Liquid spec.
#
# Run with: liquid-spec run adapter.rb

require "liquid"
require_relative "lib/liquid_il"

LiquidSpec.configure do |config|
  config.suite = :liquid_ruby
end

# Compile a template string into a LiquidIL template object.
# The compiled template is stored in ctx[:template] for use by the render block.
LiquidSpec.compile do |ctx, source, options|
  file_system = options[:file_system] || ctx[:file_system]
  # liquid-spec specs without error_mode expect lax behavior;
  # default to lax, override only when the spec explicitly sets one
  error_mode = options[:error_mode] || :lax
  c = LiquidIL::Context.new(file_system: file_system, error_mode: error_mode)
  ctx[:template] = c.parse(source, line_numbers: options[:line_numbers])
end

# Render the compiled template (stored in ctx[:template]) with the given assigns.
LiquidSpec.render do |ctx, assigns, options|
  opts = options || {}
  ctx[:template].render(assigns, **opts)
end
