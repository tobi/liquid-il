#!/usr/bin/env ruby
# frozen_string_literal: true

# Combined optimized + AOT-compiled Ruby adapter for liquid-spec
# Uses LiquidIL::Optimizer for IL optimization + LiquidIL::Compiler::Ruby for AOT compilation

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
  # Create optimized context for parsing
  context = LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors]
  )

  optimized_context = LiquidIL::Optimizer.optimize(context)

  # Parse with optimized context
  template = optimized_context.parse(source)
  ctx[:context] = optimized_context
  ctx[:template] = template
end

LiquidSpec.render do |ctx, assigns, render_options|
  ctx[:template].render(assigns)
end
