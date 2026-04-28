#!/usr/bin/env ruby
# frozen_string_literal: true

# LiquidIL adapter for liquid-spec
# Uses the ruby compiler which generates YJIT-friendly Ruby.

require "liquid/spec/cli/adapter_dsl"
require_relative "support/liquid_spec_adapter_helper"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |_ctx|
  require "liquid"
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.missing_features = LiquidSpecAdapterHelper::BASIC_MISSING_FEATURES
  config.known_failures = LiquidSpecAdapterHelper.known_failures
end

# Fallback for templates that can't be compiled (dynamic partials, recursion, etc.)
class FallbackTemplate
  def initialize(error)
    @error = error
  end

  def render(assigns = {}, render_errors: true, **_)
    if render_errors
      case @error
      when LiquidIL::SyntaxError
        "Liquid syntax error (line #{@error.line}): #{@error.message}"
      else
        ""
      end
    else
      raise @error
    end
  end
end

LiquidSpec.compile do |ctx, source, compile_options|
  context = LiquidIL::Context.new(**LiquidSpecAdapterHelper.context_options(compile_options))

  ctx[:context] = context
  begin
    ctx[:template] = context.parse(source)
  rescue LiquidIL::SyntaxError
    # Let syntax errors propagate — liquid-spec runner detects them as parse_error
    raise
  rescue => e
    ctx[:template] = FallbackTemplate.new(e)
  end
end

LiquidSpec.render do |ctx, assigns, render_options|
  LiquidSpecAdapterHelper.with_frozen_time do
    ctx[:template].render(assigns, **LiquidSpecAdapterHelper.render_options(render_options))
  end
end
