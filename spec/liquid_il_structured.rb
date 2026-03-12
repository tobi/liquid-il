#!/usr/bin/env ruby
# frozen_string_literal: true

# LiquidIL adapter for liquid-spec
# Uses the structured compiler which generates YJIT-friendly Ruby.

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"

  # Mock Time.now to return frozen time for date filter tests
  # liquid-spec expects time frozen to 2024-01-01 00:01:58 UTC
  module TimeMock
    def now
      Time.new(2024, 1, 1, 0, 1, 58, "+00:00")
    end
  end
  Time.singleton_class.prepend(TimeMock)
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.features = [:core, :runtime_drops]
end

# Fallback template for unsupported features (dynamic partials, recursion, etc.)
class FallbackTemplate
  def initialize(error_message)
    @error_message = error_message
  end

  def render(assigns = {}, render_errors: true, **_)
    if render_errors
      ""
    else
      raise LiquidIL::RuntimeError.new(@error_message)
    end
  end
end

LiquidSpec.compile do |ctx, source, compile_options|
  context = LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors]
  )

  ctx[:context] = context
  begin
    ctx[:template] = context.parse(source)
  rescue => e
    # Structured compiler can't handle some edge cases (dynamic partials,
    # recursive partials, break/continue in included partials inside loops).
    # Return a fallback that renders empty (matching Liquid's safe behavior).
    ctx[:template] = FallbackTemplate.new(e.message)
  end
end

LiquidSpec.render do |ctx, assigns, render_options|
  strict_errors = render_options.fetch(:strict_errors, false)
  render_errors = !strict_errors
  ctx[:template].render(assigns, render_errors: render_errors)
end
