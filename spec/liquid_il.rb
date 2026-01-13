#!/usr/bin/env ruby
# frozen_string_literal: true

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.features = [:core, :runtime_drops]
end

LiquidSpec.compile do |ctx, source, compile_options|
  context = LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors]
  )

  ctx[:context] = context
  ctx[:template] = context.parse(source)
end

LiquidSpec.render do |ctx, assigns, render_options|
  render_errors = render_options.fetch(:render_errors, true)
  ctx[:template].render(assigns, render_errors: render_errors)
end
