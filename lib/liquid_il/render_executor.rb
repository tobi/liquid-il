# frozen_string_literal: true

module LiquidIL
  # One semantic execution path for Context-backed Template instances and lean
  # cross-process CompiledArtifact instances. Public wrappers only translate
  # their configuration into a Scope; invocation and error formatting live here.
  module RenderExecutor
    module_function

    def build_scope(assigns, context: nil, registers: nil, render_errors: true,
                    static_environments: nil, strict_variables: nil,
                    strict_filters: nil, resource_limits: nil,
                    partial_provider: nil)
      base_registers = context&.registers
      regs = if registers
        base_registers ? base_registers.merge(registers) : registers
      else
        base_registers ? base_registers.dup : EMPTY_HASH
      end

      scope = Scope.new(
        assigns,
        registers: regs,
        strict_errors: context&.strict_errors || false,
        static_environments: static_environments,
      )
      scope.file_system = context&.file_system || regs["file_system"] || regs[:file_system]
      scope.render_errors = render_errors
      scope.strict_variables = strict_variables.nil? ? (context&.strict_variables || false) : strict_variables
      scope.strict_filters = strict_filters.nil? ? (context&.strict_filters || false) : strict_filters

      custom_filters = context&.custom_filters
      if custom_filters && !custom_filters.empty?
        scope.custom_filters = custom_filters
      else
        global = Filters.global_registry
        scope.custom_filters = global unless global.empty?
      end

      limits = resource_limits.is_a?(Hash) ? resource_limits.dup : resource_limits
      scope.resource_limits = limits || context&.resource_limits if limits || context&.resource_limits
      scope.partial_provider = partial_provider if partial_provider
      scope
    end

    def call(compiled_proc, scope, partial_constants = nil, output: nil)
      result = if partial_constants
        compiled_proc.call(scope, partial_constants)
      else
        compiled_proc.call(scope)
      end
      output ? (output << result) : result
    rescue LiquidIL::ResourceLimitError => e
      raise unless scope.render_errors
      append_error(output, (e.partial_output || "") + "Liquid error: #{LiquidIL.clean_error_message(e.message)}")
    rescue LiquidIL::RuntimeError => e
      raise unless scope.render_errors
      prefix = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      append_error(output, prefix + "Liquid error (#{location}): #{e.message}")
    rescue StandardError => e
      raise unless scope.render_errors
      append_error(output, "Liquid error (line 1): #{LiquidIL.clean_error_message(e.message)}")
    end

    def append_error(output, message)
      output ? (output << message) : message
    end
    private_class_method :append_error
  end
end
