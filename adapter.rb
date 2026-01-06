#!/usr/bin/env ruby
# frozen_string_literal: true

require "liquid/spec/cli/adapter_dsl"
require_relative "lib/liquid_il"

# File system adapter that wraps various file system implementations
class FileSystemAdapter
  def initialize(fs)
    @fs = fs
  end

  def read(name)
    if @fs.respond_to?(:read_template_file)
      @fs.read_template_file(name) rescue nil
    elsif @fs.respond_to?(:read)
      @fs.read(name)
    elsif @fs.is_a?(Hash)
      @fs[name] || @fs["#{name}.liquid"] || @fs[name.to_s.sub(/\.liquid$/, "")]
    end
  end
end

LiquidSpec.setup do |ctx|
  require "liquid"
end

LiquidSpec.configure do |config|
  config.suite = :liquid_ruby
  config.features = [:core]
end

LiquidSpec.compile do |ctx, source, options|
  LiquidIL.parse(source)
end

LiquidSpec.render do |ctx, template, assigns, options|
  registers = options[:registers] || options["registers"] || {}
  fs_obj = registers[:file_system] || registers["file_system"]
  file_system = fs_obj ? FileSystemAdapter.new(fs_obj) : nil
  strict = options[:strict_errors] || options["strict_errors"] || false

  # Create a context with the file system and render
  liquid_ctx = LiquidIL::Context.new(
    file_system: file_system,
    registers: registers,
    strict_errors: strict
  )

  # Re-bind the template to this context for rendering
  LiquidIL::Template.new(template.source, template.instructions, template.spans, liquid_ctx).render(assigns)
end
