# frozen_string_literal: true

require_relative "liquid_il/lexer"
require_relative "liquid_il/parser"
require_relative "liquid_il/il"
require_relative "liquid_il/compiler"
require_relative "liquid_il/utils"
require_relative "liquid_il/vm"
require_relative "liquid_il/context"
require_relative "liquid_il/drops"
require_relative "liquid_il/filters"
require_relative "liquid_il/pretty_printer"

module LiquidIL
  class Error < StandardError; end
  class SyntaxError < Error
    attr_accessor :position, :source
    def initialize(message, position: nil, source: nil)
      super(message)
      @position = position
      @source = source
    end

    def line
      return 1 unless @position && @source
      @source[0, @position].count("\n") + 1
    end
  end
  class RuntimeError < Error
    attr_accessor :file, :line, :partial_output
    def initialize(message, file: nil, line: 1, partial_output: nil)
      super(message)
      @file = file
      @line = line
      @partial_output = partial_output
    end
  end

  # Context is the main entry point for rendering Liquid templates.
  # It holds configuration like file_system and can parse/render templates.
  #
  #   ctx = LiquidIL::Context.new
  #   ctx.render("Hello {{ name }}", name: "World")  # => "Hello World"
  #
  #   # With file system for includes
  #   ctx = LiquidIL::Context.new(file_system: my_fs)
  #   template = ctx.parse("{% include 'header' %}")
  #   template.render(title: "Home")
  #
  class Context
    attr_accessor :file_system, :strict_errors, :registers

    def initialize(file_system: nil, strict_errors: false, registers: {})
      @file_system = file_system
      @strict_errors = strict_errors
      @registers = registers
    end

    # Parse a template string, returning a Template bound to this context
    #
    #   template = ctx.parse("Hello {{ name }}")
    #   template.render(name: "World")
    #
    def parse(source, **options)
      result = Compiler.new(source, **options).compile
      Template.new(source, result[:instructions], result[:spans], self)
    end

    # One-shot render - parse and render in a single call
    #
    #   ctx.render("Hello {{ name }}", name: "World")
    #
    def render(source, assigns = {}, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      parse(source).render(assigns)
    end

    # Hash-style access for templates (with caching)
    #
    #   ctx["Hello {{ name }}"].render(name: "World")
    #
    def [](source)
      @cache ||= {}
      @cache[source] ||= parse(source)
    end

    # Clear the template cache
    def clear_cache
      @cache&.clear
    end
  end

  # A parsed template ready for rendering
  class Template
    attr_reader :source, :instructions, :spans

    def initialize(source, instructions, spans = nil, context = nil)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
    end

    # Render the template with the given variables
    #
    #   template.render(name: "World")
    #   template.render({ "name" => "World" })
    #
    def render(assigns = {}, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = Scope.new(assigns, registers: @context&.registers&.dup || {}, strict_errors: @context&.strict_errors || false)
      scope.file_system = @context&.file_system
      begin
        VM.execute(@instructions, scope, spans: @spans, source: @source)
      rescue LiquidIL::RuntimeError => e
        output = e.partial_output || ""
        location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
        output + "Liquid error (#{location}): #{e.message}"
      end
    end

    class << self
      # Standalone parse (creates an unbound template)
      def parse(source, **options)
        result = Compiler.new(source, **options).compile
        new(source, result[:instructions], result[:spans])
      end
    end
  end

  # Module-level convenience methods (use default context)
  class << self
    # Parse a template string
    #
    #   template = LiquidIL.parse("Hello {{ name }}")
    #
    def parse(source, **options)
      Template.parse(source, **options)
    end

    # One-shot render
    #
    #   LiquidIL.render("Hello {{ name }}", name: "World")
    #
    def render(source, assigns = {}, **options)
      Template.parse(source).render(assigns, **options)
    end
  end
end
