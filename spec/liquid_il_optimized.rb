#!/usr/bin/env ruby
# frozen_string_literal: true

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"
  ctx[:optimized_context] = LiquidIL::Optimizer.optimize(LiquidIL::Context.new)
end

# Wrapper to adapt liquid-spec's file system to our expected interface
class FileSystemAdapter
  def initialize(fs)
    @fs = fs
  end

  def read(name)
    @fs.read_template_file(name)
  rescue Liquid::FileSystemError
    nil  # Return nil for missing files - VM will handle the error
  end
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.features = [:core, :runtime_drops]
end

LiquidSpec.compile do |ctx, source, options|
  options ||= {}
  registers = options[:registers] || {}
  raw_fs = registers[:file_system]
  file_system = raw_fs ? FileSystemAdapter.new(raw_fs) : nil

  optimized_ctx = LiquidIL::Optimizer.optimize(LiquidIL::Context.new(file_system: file_system))
  ctx[:template] = optimized_ctx.parse(source)
end

LiquidSpec.render do |ctx, assigns, options|
  options ||= {}
  template = ctx[:template]

  registers = options[:registers] || {}
  raw_fs = registers[:file_system]
  file_system = raw_fs ? FileSystemAdapter.new(raw_fs) : nil
  strict = options[:strict_errors]

  # Create a context and bind it to the template for rendering
  liquid_ctx = LiquidIL::Context.new(
    file_system: file_system,
    registers: registers,
    strict_errors: strict || false
  )

  # Create a new template bound to this context
  bound_template = LiquidIL::Template.new(
    template.source,
    template.instructions,
    template.spans,
    liquid_ctx
  )

  bound_template.render(assigns || {})
end
