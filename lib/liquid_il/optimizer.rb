# frozen_string_literal: true

module LiquidIL
  # Optimizer - wraps a Context with default compile-time optimizations
  class Optimizer
    def self.optimize(context, **options)
      return context if context.is_a?(OptimizedContext)
      unless context.is_a?(Context)
        raise ArgumentError, "expected LiquidIL::Context, got #{context.class}"
      end

      OptimizedContext.new(context, **options)
    end
  end

  # Context wrapper that applies default compiler options
  class OptimizedContext < Context
    attr_reader :default_compile_options

    def initialize(base_context, **options)
      @file_system = base_context.file_system
      @strict_errors = base_context.strict_errors
      @registers = base_context.registers
      inline_opts = { inline_partials: true }
      inline_opts[:file_system] = @file_system if @file_system
      @default_compile_options = { optimize: true }.merge(inline_opts).merge(options)
    end

    def parse(source, **options)
      merged = @default_compile_options.merge(options)
      super(source, **merged)
    end
  end
end
