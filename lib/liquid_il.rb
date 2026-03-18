# frozen_string_literal: true

require_relative "liquid_il/lexer"
require_relative "liquid_il/tags"
require_relative "liquid_il/parser"
require_relative "liquid_il/il"
require_relative "liquid_il/passes"
require_relative "liquid_il/compiler"
require_relative "liquid_il/utils"
require_relative "liquid_il/context"
require_relative "liquid_il/drops"
require_relative "liquid_il/filters"
require_relative "liquid_il/pretty_printer"
require_relative "liquid_il/structured_compiler"

module LiquidIL
  EMPTY_ARRAY = [].freeze
  EMPTY_HASH = {}.freeze

  class Error < StandardError; end

  class ErrorMarker
    attr_reader :message, :location
    def initialize(message, location)
      @message = message
      @location = location
    end
    def to_s
      "Liquid error (#{@location}): #{@message}"
    end
  end

  # Strip "Liquid error: " prefix to avoid double-wrapping
  def self.clean_error_message(message)
    message.to_s.sub(/\ALiquid error: /i, "")
  end

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

  # Context holds configuration (file_system, etc.) and compiles templates.
  #
  #   ctx = LiquidIL::Context.new
  #   ctx.render("Hello {{ name }}", name: "World")  # => "Hello World"
  #
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

    # Parse a template string, returning a compiled Template.
    def parse(source, **options)
      options = options.merge(file_system: @file_system) if @file_system && !options.key?(:file_system)
      Compiler::Structured.compile(source, context: self, **options)
    end

    # Hash-style access with caching.
    def [](source)
      @cache ||= {}
      @cache[source] ||= parse(source)
    end

    def clear_cache
      @cache&.clear
    end

    # One-shot render.
    def render(source, assigns = {}, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      parse(source).render(assigns)
    end
  end

  require_relative "liquid_il/optimizer"

  # A compiled template ready for rendering.
  #
  #   template = LiquidIL.parse("Hello {{ name }}")
  #   template.render(name: "World")         # => "Hello World"
  #   template.to_ruby("MyTemplate")         # => Ruby source string
  #   template.write_ruby("my_template.rb")  # writes standalone file
  #
  class Template
    attr_reader :source, :instructions, :spans, :compiled_source

    def initialize(source, instructions, spans, context, compiled_result)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @partial_constants = compiled_result.partial_constants
    end

    # Render the template with the given variables.
    def render(assigns = {}, render_errors: true, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      ctx = @context
      regs = ctx&.registers
      scope = Scope.new(assigns, registers: regs ? regs.dup : EMPTY_HASH, strict_errors: ctx&.strict_errors || false)
      scope.file_system = ctx&.file_system
      scope.render_errors = render_errors

      if @partial_constants
        @compiled_proc.call(scope, @spans, @source, @partial_constants)
      else
        @compiled_proc.call(scope, @spans, @source)
      end
    rescue LiquidIL::RuntimeError => e
      raise unless render_errors
      output = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output + "Liquid error (#{location}): #{e.message}"
    rescue StandardError => e
      raise unless render_errors
      "Liquid error (line 1): #{LiquidIL.clean_error_message(e.message)}"
    end

    # Generate standalone Ruby source code as a module.
    #
    #   template.to_ruby("ProductCard")
    #   # => "module ProductCard\n  extend self\n  def render(assigns = {})\n  ...\nend\n"
    #
    # The generated module:
    # - Requires "liquid_il" for runtime helpers (Scope, Filters, etc.)
    # - Exposes `ModuleName.render(assigns)` for rendering
    # - Can be loaded with `require` and called directly
    #
    def to_ruby(module_name = "CompiledLiquidTemplate")
      raise ArgumentError, "module_name must be a valid Ruby constant" unless module_name.match?(/\A[A-Z][a-zA-Z0-9_]*\z/)
      raise "No compiled source available" unless @compiled_source

      generate_standalone_ruby(module_name)
    end

    # Write standalone Ruby source to a file.
    #
    #   template.write_ruby("product_card.rb", module_name: "ProductCard")
    #
    def write_ruby(filename, module_name: nil)
      module_name ||= File.basename(filename, ".rb").split("_").map(&:capitalize).join
      File.write(filename, to_ruby(module_name))
    end

    # Pretty-print IL instructions (for debugging).
    def dump_il(io = $stdout, color: true)
      PrettyPrinter.new(@instructions, color: color, source: @source, spans: @spans).dump(io)
    end

    def il_to_s(color: true)
      PrettyPrinter.new(@instructions, color: color, source: @source, spans: @spans).to_s
    end

    class << self
      # Standalone parse (no context needed).
      #
      #   template = LiquidIL::Template.parse("Hello {{ name }}")
      #   template.render(name: "World")
      #
      def parse(source, **options)
        Compiler::Structured.compile(source, **options)
      end
    end

    private

    def generate_standalone_ruby(module_name)
      proc_body = extract_proc_body(@compiled_source)

      <<~RUBY
        # frozen_string_literal: true
        #
        # Auto-generated by LiquidIL (structured compiler)
        # Source template:
        #{@source.lines.map { |l| "#   #{l.chomp}" }.join("\n")}
        #
        # Usage:
        #   require_relative "this_file"
        #   output = #{module_name}.render({"name" => "World"})
        #

        begin; require "liquid_il"; rescue LoadError; end

        module #{module_name}
          extend self

          SPANS = #{@spans.inspect}.freeze
          SOURCE = #{@source.inspect}.freeze

          def render(assigns = {}, render_errors: true)
            __scope__ = LiquidIL::Scope.new(assigns)
            __scope__.render_errors = render_errors
            __spans__ = SPANS
            __template_source__ = SOURCE

        #{indent_body(proc_body, 4)}

            __output__
          rescue LiquidIL::RuntimeError => e
            raise unless render_errors
            output = e.partial_output || ""
            location = e.file ? "\#{e.file} line \#{e.line}" : "line \#{e.line}"
            output + "Liquid error (\#{location}): \#{e.message}"
          rescue StandardError => e
            raise unless render_errors
            "Liquid error (line 1): \#{LiquidIL.clean_error_message(e.message)}"
          end
        end
      RUBY
    end

    def extract_proc_body(source)
      lines = source.lines
      start_idx = lines.index { |l| l.match?(/^proc do \|/) }
      return "" unless start_idx

      body_lines = lines[(start_idx + 1)..]
      # Remove trailing __output__ and end
      body_lines.pop while body_lines.last&.match?(/^\s*(end|__output__)\s*$/)
      body_lines.join
    end

    def indent_body(code, extra_spaces)
      indent = " " * extra_spaces
      code.lines.map { |l| l.strip.empty? ? "\n" : "#{indent}#{l}" }.join
    end
  end

  # Module-level convenience methods.
  class << self
    # Parse a template string.
    def parse(source, **options)
      Compiler::Structured.compile(source, **options)
    end

    # One-shot render.
    def render(source, assigns = {}, **options)
      parse(source).render(assigns, **options)
    end
  end
end
