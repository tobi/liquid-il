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
      # Liquid-spec SimpleFileSystem
      @fs.read_template_file(name) rescue nil
    elsif @fs.respond_to?(:read)
      @fs.read(name)
    elsif @fs.is_a?(Hash)
      @fs[name] || @fs["#{name}.liquid"] || @fs[name.to_s.sub(/\.liquid$/, "")]
    else
      nil
    end
  end
end

LiquidSpec.setup do |ctx|
  # Context setup runs once before all tests
  # Load liquid gem for test infrastructure (drops, etc.)
  require "liquid"
end

LiquidSpec.configure do |config|
  config.suite = :liquid_ruby
  config.features = []  # Start with minimal features, expand as we pass tests
end

LiquidSpec.compile do |ctx, source, options|
  # Compile returns an opaque template object
  LiquidIL::Template.parse(source)
end

LiquidSpec.render do |ctx, template, assigns, options|
  # Get registers from options
  registers = options[:registers] || options["registers"] || {}

  # File system is passed via registers[:file_system] by liquid-spec
  file_system = nil
  fs_obj = registers[:file_system] || registers["file_system"]
  if fs_obj
    file_system = FileSystemAdapter.new(fs_obj)
  end

  # Create context with file system
  context = LiquidIL::Context.new(
    assigns,
    registers: registers,
    strict_errors: options[:strict_errors] || options["strict_errors"] || false
  )
  context.file_system = file_system

  # Execute
  LiquidIL::VM.execute(template.instructions, context)
end
