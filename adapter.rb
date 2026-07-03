# frozen_string_literal: true

# Liquid Spec Adapter for LiquidIL
#
# Tests LiquidIL against the official Liquid spec.
#
# Run with: liquid-spec run adapter.rb

require "liquid"
require_relative "lib/liquid_il"
require_relative "spec/helpers/shopify_mock"

LiquidIL::ShopifyMock.install!

LiquidSpec.configure do |config|
  # LiquidIL::ShopifyMock provides Shopify theme tags/filters/objects for
  # liquid-spec's shopify_* suites. Shopify-specific include quirks and
  # production error formatting remain outside this adapter surface.
  config.missing_features = [:shopify_includes, :shopify_error_handling]
end

# Compile a template string into a LiquidIL template object.
# The compiled template is stored in ctx[:template] for use by the render block.
LiquidSpec.compile do |ctx, source, options|
  file_system = options[:file_system] || ctx[:file_system]
  file_system = LiquidIL::ShopifyMock.wrap_file_system(file_system) if LiquidIL::ShopifyMock.shopify_template?(source)
  # liquid-spec specs without error_mode expect lax behavior;
  # default to lax, override only when the spec explicitly sets one
  error_mode = options[:error_mode] || :lax
  c = LiquidIL::Context.new(file_system: file_system, error_mode: error_mode)
  ctx[:template] = c.parse(source, line_numbers: options[:line_numbers])
end

# Render the compiled template (stored in ctx[:template]) with the given assigns.
LiquidSpec.render do |ctx, assigns, options|
  opts = options || {}
  LiquidIL::ShopifyMock.prepare_environment!(assigns)
  ctx[:template].render(assigns, **opts)
end
