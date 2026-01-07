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
  optimized_ctx = LiquidIL::Optimizer.optimize(LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors]
  ))

  # Parse with optimized context, then compile to Ruby
  template = optimized_ctx.parse(source)
  ctx[:context] = optimized_ctx
  ctx[:template] = LiquidIL::Compiler::Ruby.compile(template)
end

LiquidSpec.render do |ctx, assigns, render_options|
  ctx[:template].render(assigns)
end
