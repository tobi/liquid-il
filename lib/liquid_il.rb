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
require_relative "liquid_il/ruby_compiler"
require_relative "liquid_il/strainer_template"

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
  # Error raised when strict_filters is enabled and an undefined filter is used
  class UndefinedFilter < Error; end

  # Error raised when strict_variables is enabled and an undefined variable is accessed
  class UndefinedVariable < Error; end

  # Error raised when resource limits are exceeded
  class ResourceLimitError < Error; end

  class Context
    attr_accessor :file_system, :strict_errors, :registers
    attr_reader :custom_filters, :strict_variables, :strict_filters, :resource_limits, :error_mode

    def initialize(file_system: nil, strict_errors: false, registers: {},
                   strict_variables: false, strict_filters: false,
                   resource_limits: nil, error_mode: :lax)
      @file_system = file_system
      @strict_errors = strict_errors
      @registers = registers
      @strict_variables = strict_variables
      @strict_filters = strict_filters
      @resource_limits = resource_limits  # { output_limit: N, render_score_limit: N }
      @error_mode = error_mode  # :lax, :warn, :strict
      # Seed custom filters from global registry; per-context register_filter can override
      global = LiquidIL::Filters.global_registry
      @custom_filters = global.empty? ? {} : global.dup
      # Strainer class for filter dispatch — filter modules are included into this
      @strainer_class = Class.new(LiquidIL::StrainerTemplate)
    end

    attr_reader :strainer_class

    # Register custom filter methods from a module.
    #
    #   ctx.register_filter(MoneyFilters)              # impure (can access scope)
    #   ctx.register_filter(MathFilters, pure: true)   # pure (no scope access, inlineable)
    #
    # Pure filters are called directly at render time with zero dispatch overhead.
    # Impure filters go through the standard filter dispatch with scope access.
    #
    def register_filter(mod, pure: false)
      methods = if mod.is_a?(Module)
        mod.instance_methods(false)
      else
        raise ArgumentError, "register_filter expects a Module, got #{mod.class}"
      end

      @strainer_class.add_filter(mod)

      methods.each do |name|
        name_s = name.to_s
        @custom_filters[name_s] = {
          module: mod,
          pure: pure,
          method: mod.instance_method(name),
        }
      end

      # Invalidate template cache since filter availability changed
      clear_cache
    end

    # Check if a filter name is known (built-in or custom)
    def filter_known?(name)
      LiquidIL::Filters.valid_filter_methods[name] || @custom_filters.key?(name)
    end

    # Register a custom tag.
    #
    # Simple tags (no block):
    #   ctx.register_tag("section", mode: :raw)  # captures raw body
    #   ctx.register_tag("schema", mode: :discard)  # discards body
    #   ctx.register_tag("style", mode: :passthrough)  # evaluates body normally
    #
    # Block tags with callbacks:
    #   ctx.register_tag("form", mode: :passthrough,
    #     setup: ->(args, builder) { builder.write_raw("<form>") },
    #     teardown: ->(args, builder) { builder.write_raw("</form>") })
    #
    # This registers on the global Tags registry (tags affect parsing, which
    # is global). For per-context isolation, use separate processes.
    #
    def register_tag(name, end_tag: nil, mode: :passthrough, setup: nil, teardown: nil,
                     on_parse: nil, handler: nil, parse_args: nil)
      end_tag ||= "end#{name}" if mode != :custom || (mode == :custom && handler&.respond_to?(:before_block))
      Tags.register(name, end_tag: end_tag, mode: mode, setup: setup, teardown: teardown,
                    on_parse: on_parse, handler: handler, parse_args: parse_args)
      clear_cache
    end

    # Parse a template string, returning a compiled Template.
    def parse(source, **options)
      options = options.merge(file_system: @file_system) if @file_system && !options.key?(:file_system)
      Compiler::Ruby.compile(source, context: self, **options)
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
    attr_reader :source, :instructions, :spans, :compiled_source, :errors, :warnings

    def initialize(source, instructions, spans, context, compiled_result, iseq_binary: nil)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @partial_constants = compiled_result.partial_constants
      @iseq_binary = iseq_binary
      @errors = []
      @warnings = []
    end

    # Returns the ISeq binary for this template's compiled proc.
    # After normal compilation, the binary is already in RubyCompiler's
    # @@iseq_cache — so this is a free O(1) lookup, not a recompilation.
    # For templates created via from_cache, @iseq_binary is preset via constructor.
    def iseq_binary
      @iseq_binary ||= RubyCompiler.iseq_binary_for(@compiled_source)
    end

    # Everything needed to reconstruct this template without recompilation.
    # Roundtrips with Template.from_cache:
    #
    #   data = template.cache_data
    #   restored = LiquidIL::Template.from_cache(**data)
    #
    # Note: ISeq binaries are not portable across Ruby versions.
    def cache_data
      {
        source: @source,
        spans: @spans,
        iseq_binary: iseq_binary,
        partial_constants: @partial_constants,
      }
    end

    # Reconstruct a Template from cached components (no recompilation needed).
    # Accepts the output of #cache_data.
    #
    #   data = template.cache_data
    #   restored = LiquidIL::Template.from_cache(**data)
    #
    def self.from_cache(source:, spans:, iseq_binary:, partial_constants: nil)
      compiled_proc = RubyVM::InstructionSequence.load_from_binary(iseq_binary).eval
      result = RubyCompiler::CompilationResult.new(
        proc: compiled_proc,
        source: nil,
        can_compile: true,
        partial_constants: partial_constants,
      )
      new(source, [], spans, nil, result, iseq_binary: iseq_binary)
    end

    # Render the template with the given variables.
    #
    #   template.render(name: "World")
    #   template.render({ "x" => 1 }, registers: { page_type: "product" })
    #   template.render({ "x" => 1 }, strict_variables: true, strict_filters: true)
    #
    def render(assigns = {}, render_errors: true, registers: nil,
               strict_variables: nil, strict_filters: nil,
               liquid_context: nil,
               **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      ctx = @context
      # Merge context-level and render-time registers
      base_regs = ctx&.registers
      if registers
        regs = base_regs ? base_regs.merge(registers) : registers
      else
        regs = base_regs ? base_regs.dup : EMPTY_HASH
      end
      scope = Scope.new(assigns, registers: regs, strict_errors: ctx&.strict_errors || false,
                        liquid_context: liquid_context)
      scope.file_system = ctx&.file_system || liquid_context&.registers&.[](:file_system)
      scope.render_errors = render_errors
      # strict_variables: render-time overrides context-level
      scope.strict_variables = strict_variables.nil? ? (ctx&.strict_variables || false) : strict_variables
      # strict_filters: render-time overrides context-level
      scope.strict_filters = strict_filters.nil? ? (ctx&.strict_filters || false) : strict_filters
      # Custom filters from context, falling back to global registry (needed for from_cache templates where @context is nil)
      custom_filters = ctx&.custom_filters
      if custom_filters && !custom_filters.empty?
        scope.custom_filters = custom_filters
      else
        global = LiquidIL::Filters.global_registry
        scope.custom_filters = global unless global.empty?
      end
      # Build strainer instance for filter dispatch
      strainer_class = ctx&.strainer_class || Class.new(LiquidIL::StrainerTemplate)
      scope.strainer = strainer_class.new(scope)
      # Resource limits from context
      scope.resource_limits = ctx&.resource_limits if ctx&.resource_limits

      if @partial_constants
        @compiled_proc.call(scope, @spans, @source, @partial_constants)
      else
        @compiled_proc.call(scope, @spans, @source)
      end
    rescue LiquidIL::ResourceLimitError => e
      raise unless render_errors
      "Liquid error: #{e.message}"
    rescue LiquidIL::RuntimeError => e
      raise unless render_errors
      output = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output + "Liquid error (#{location}): #{e.message}"
    rescue StandardError => e
      raise unless render_errors
      "Liquid error (line 1): #{LiquidIL.clean_error_message(e.message)}"
    end

    # Strict render — raises on any error instead of rendering inline.
    def render!(assigns = {}, **options)
      render(assigns, render_errors: false, **options)
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
      PrettyPrinter.new(@instructions, color: color, source: @source, spans: @spans).print(io)
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
        Compiler::Ruby.compile(source, **options)
      end
    end

    private

    def generate_standalone_ruby(module_name)
      proc_body = extract_proc_body(@compiled_source)

      <<~RUBY
        # frozen_string_literal: true
        #
        # Auto-generated by LiquidIL (ruby compiler)
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

    private

    attr_writer :iseq_binary
  end

  # Module-level convenience methods.
  class << self
    # Parse a template string.
    def parse(source, **options)
      Compiler::Ruby.compile(source, **options)
    end

    # One-shot render.
    def render(source, assigns = {}, **options)
      parse(source).render(assigns, **options)
    end

    # Register a filter module globally. All new Contexts will inherit it.
    #
    #   LiquidIL.register_filter(MoneyFilters, pure: true)
    #   LiquidIL.register_filter(ShopifyFilters)
    #
    def register_filter(mod, pure: false)
      Filters.register(mod, pure: pure)
    end
  end
end
