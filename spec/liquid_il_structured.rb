#!/usr/bin/env ruby
# frozen_string_literal: true

# YJIT-friendly structured Ruby adapter for liquid-spec
# Uses StructuredCompiler which generates native Ruby control flow (if/else, each)
# instead of state machine dispatch. This should perform better with YJIT.

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"

  # Mock Time.now to return 2024 for date filter tests
  # liquid-spec expects dates to be in 2024
  module TimeMock
    def now
      Time.new(2024, 1, 1, 0, 0, 0, "+00:00")
    end
  end
  Time.singleton_class.prepend(TimeMock)
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

  template = context.parse(source)
  ctx[:context] = context
  ctx[:template] = LiquidIL::Compiler::Structured.compile(template)
end

LiquidSpec.render do |ctx, assigns, render_options|
  render_errors = render_options.fetch(:render_errors, true)
  ctx[:template].render(assigns, render_errors: render_errors)
end
