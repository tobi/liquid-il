#!/usr/bin/env ruby
# frozen_string_literal: true

# LiquidIL adapter for liquid-spec
# Uses the ruby compiler which generates YJIT-friendly Ruby.

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |_ctx|
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
  # Run all default suites, excluding Shopify runtime extensions that require
  # Shopify theme objects, filters, include quirks, or production error formats
  # outside core LiquidIL.
  config.missing_features = [
    :shopify_tags,
    :shopify_objects,
    :shopify_filters,
    :shopify_includes,
    :shopify_error_handling,
  ]
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
  context = LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors],
    strict_variables: compile_options[:strict_variables] || false,
    strict_filters: compile_options[:strict_filters] || false,
    # liquid-spec supplies resource limits at render time. Compile the adapter
    # templates with instrumentation enabled so those dynamic limits can fire.
    resource_limits: compile_options[:resource_limits] || { render_score_limit: 1 << 60 },
    error_mode: compile_options[:error_mode] || :strict
  )

  ctx[:context] = context
  begin
    ctx[:template] = context.parse(source,
      template_name: compile_options[:template_name],
      line_numbers: compile_options[:line_numbers])
  rescue LiquidIL::SyntaxError
    # Let syntax errors propagate — liquid-spec runner detects them as parse_error
    raise
  rescue => e
    ctx[:template] = FallbackTemplate.new(e)
  end
end

LiquidSpec.render do |ctx, assigns, render_options|
  strict_errors = render_options.fetch(:strict_errors, false)
  render_errors = render_options.fetch(:render_errors, !strict_errors)
  # Registers passthrough: artifact-loaded templates have no compile context,
  # so dynamic partials resolve through the render-time file_system register.
  registers = render_options[:registers]
  # Mirror the reference adapter: the spec environment is passed as
  # static_environments (visible inside isolated {% render %} partials),
  # with an empty mutable scope — see Liquid::Context.build in
  # examples/liquid_ruby.rb.
  ctx[:template].render({}, render_errors: render_errors, registers: registers,
    static_environments: assigns, resource_limits: render_options[:resource_limits])
end

# Compiled-artifact protocol: the production path this implementation is
# optimized for (compile once -> persist LQIL blob -> cold load+render).
LiquidSpec.dump_artifact do |ctx|
  ctx[:template].to_artifact
end

LiquidSpec.load_artifact do |ctx, blob, _options|
  ctx[:template] = LiquidIL::Artifact.load(blob)
end
