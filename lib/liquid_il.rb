# frozen_string_literal: true

require_relative "liquid_il/lexer"
require_relative "liquid_il/core_ext"
require_relative "liquid_il/tags"
require_relative "liquid_il/parser"
require_relative "liquid_il/il"
require_relative "liquid_il/passes"
require_relative "liquid_il/compiler"
require_relative "liquid_il/utils"
require_relative "liquid_il/context"
require_relative "liquid_il/drops"
require_relative "liquid_il/filters"
require_relative "liquid_il/render_executor"
require_relative "liquid_il/pretty_printer"
require_relative "liquid_il/ruby_compiler"

module LiquidIL
  EMPTY_ARRAY = [].freeze
  EMPTY_HASH = {}.freeze

  class Error < StandardError; end

  # Retained for callers that raise an explicit LiquidIL protocol error.
  # Plain objects use Ruby's native missing-method dispatch, matching
  # reference Liquid and preserving method_missing-based proxy objects.
  class NoMethodError < ::NoMethodError; end

  class ErrorMarker
    include IdentityToLiquid
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
      @position = position
      @source = source
      if position && source && !message.to_s.match?(/\bline \d+\b/i)
        super("Liquid syntax error (line #{line}): #{message}")
      else
        super(message)
      end
    end

    def line
      return 1 unless @position && @source
      @source[0, @position].count("\n") + 1
    end

    # Column (1-based) within the line where the error occurred.
    # Computed lazily: only the newline count of the prefix before the
    # last newline in source[0, position]. Zero overhead on the hot path.
    def column
      return 1 unless @position && @source
      prefix = @source[0, @position]
      last_nl = prefix.rindex("\n")
      last_nl ? @position - last_nl : @position + 1
    end

    # Structured location for error_location spec checking: "line:col"
    def location
      "#{line}:#{column}"
    end
  end

  class RuntimeError < Error
    attr_accessor :file, :line, :column, :partial_output

    def initialize(message, file: nil, line: 1, column: 1, partial_output: nil)
      super(message)
      @file = file
      @line = line
      @column = column
      @partial_output = partial_output
    end

    # Structured location for error_location spec checking:
    # "line:col" (no file) or "file:line:col" (with file).
    def location
      @file ? "#{@file}:#{@line}:#{@column}" : "#{@line}:#{@column}"
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
  class ResourceLimitError < Error
    # Output rendered before the limit tripped (limits abort the render but
    # the caller gets what was produced, like reference Liquid)
    attr_accessor :partial_output
  end

  class Context
    COMPILE_CACHE_MAX = 500

    attr_accessor :file_system, :strict_errors, :registers, :partial_index
    attr_reader :custom_filters, :custom_filter_overrides, :strict_variables, :strict_filters,
                :resource_limits, :error_mode, :bug_compatible_whitespace_trimming

    def initialize(file_system: nil, strict_errors: false, registers: {},
                   strict_variables: false, strict_filters: false,
                   resource_limits: nil, error_mode: :strict2,
                   prefer_custom_filters: false,
                   custom_filter_overrides: [],
                   hoist_scope_lookups: true,
                   bug_compatible_whitespace_trimming: false,
                   partial_index: nil)
      @file_system = file_system
      # Digest index (name -> content_digest) for the external-partial compile
      # mode: resolve which partials exist and their identity WITHOUT fetching
      # bodies. See RubyCompiler#should_externalize?.
      @partial_index = partial_index
      @strict_errors = strict_errors
      @registers = registers
      @strict_variables = strict_variables
      @strict_filters = strict_filters
      @prefer_custom_filters = prefer_custom_filters
      override_names = custom_filter_overrides.respond_to?(:each_key) ? custom_filter_overrides.each_key : Array(custom_filter_overrides).each
      @custom_filter_overrides = override_names.each_with_object({}) { |name, overrides| overrides[name.to_s] = true }.freeze
      @hoist_scope_lookups = hoist_scope_lookups
      @bug_compatible_whitespace_trimming = bug_compatible_whitespace_trimming
      @resource_limits = resource_limits  # { output_limit: N, render_score_limit: N }
      @error_mode = error_mode  # :lax, :warn, :strict, :strict2
      # Seed custom filters from global registry; per-context register_filter can override
      global = LiquidIL::Filters.global_registry
      @custom_filters = global.empty? ? {} : global.dup
    end

    # Host renderers can opt out of LiquidIL's built-in filter fast paths and
    # route every filter through a request-bound Scope dispatcher instead.
    # This is required when the host overrides standard filter names (for
    # example `date` or `json`) or its filters depend on a Liquid context.
    def prefer_custom_filters?
      @prefer_custom_filters
    end

    def prefer_custom_filter?(name)
      @prefer_custom_filters || @custom_filter_overrides.key?(name.to_s)
    end

    def hoist_scope_lookups?
      @hoist_scope_lookups
    end

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
    def register_tag(name, end_tag: nil, mode: :passthrough, setup: nil, teardown: nil)
      end_tag ||= "end#{name}"
      Tags.register(name, end_tag: end_tag, mode: mode, setup: setup, teardown: teardown)
      clear_cache
    end

    # Stable description of every context input that can change generated
    # partial code. Used by the process-wide partial cache; source bytes alone
    # are insufficient when filters, limits, tags, or partial disposition vary.
    def compilation_cache_fingerprint
      filter_parts = (@custom_filters || EMPTY_HASH).sort_by { |name, _| name }.flat_map do |name, info|
        method = info[:method]
        [name, info[:pure] ? "pure" : "impure", info[:module].name, info[:module].object_id,
         method&.name, method&.source_location&.join(":")]
      end
      # Generated code only varies on whether checks are emitted. Runtime
      # limits and mutable cumulative counters must not fragment the cache.
      limit_parts = [!@resource_limits.nil?]
      [
        Artifact::COMPILER_ABI, @error_mode, @strict_variables, @strict_filters,
        @strict_errors, @prefer_custom_filters, @custom_filter_overrides.keys.sort,
        @hoist_scope_lookups, @bug_compatible_whitespace_trimming,
        Tags.version, @partial_index&.class&.name,
        @partial_index&.object_id, *limit_parts, *filter_parts
      ].freeze
    end

    # Parse a template string, returning a compiled Template. The key includes
    # parse options and the global tag-registry generation; Ruby Hash still
    # verifies equality, so ordinary hash collisions cannot alias templates.
    def parse(source, **options)
      options = options.merge(file_system: @file_system) if @file_system && !options.key?(:file_system)
      @compile_cache ||= {}
      key = [source, Tags.version, options]
      return @compile_cache[key] if @compile_cache.key?(key)

      result = Compiler::Ruby.compile(source, context: self, **options)
      @compile_cache.clear if @compile_cache.size >= COMPILE_CACHE_MAX
      @compile_cache[[source.dup.freeze, Tags.version, options.dup.freeze]] = result
      result
    end

    # Hash-style access uses the same option-complete cache as #parse.
    def [](source)
      parse(source)
    end

    def clear_cache
      @compile_cache&.clear
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
    attr_reader :source, :instructions, :compiled_source, :errors, :warnings,
                :partial_constants, :partial_dependencies, :template_metadata,
                :host_tag_metadata

    def initialize(source, instructions, context, compiled_result, iseq_binary: nil)
      @source = source
      @instructions = instructions
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @partial_constants = compiled_result.partial_constants
      # {name => {digest:, disposition: :inline|:lambda|:external}} — lets a host
      # build a composite cache key (entry digest + baked-partial digests) and
      # know which external artifacts to prefetch. nil when the template has no
      # partials. See RubyCompiler#compute_partial_dependencies.
      @partial_dependencies = compiled_result.respond_to?(:partial_dependencies) ? compiled_result.partial_dependencies : nil
      # Host-requested tag compile products, grouped by logical template name.
      # These are produced once on a compile miss and persisted alongside the
      # ISeq so artifact hits never need to reparse opaque tag source.
      @template_metadata = compiled_result.respond_to?(:template_metadata) ? compiled_result.template_metadata : nil
      @host_tag_metadata = compiled_result.respond_to?(:host_tag_metadata) ? compiled_result.host_tag_metadata : nil
      @iseq_binary = iseq_binary
      @errors = []
      @warnings = []
    end

    # Returns the ISeq binary for this template's compiled proc.
    # After normal compilation, the binary is already in RubyCompiler's
    # CompilerCaches::ISEQ — so this is a free O(1) lookup, not a recompilation.
    # For templates created via from_cache / load_iseq, @iseq_binary is preset.
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
        iseq_binary: iseq_binary,
        partial_constants: @partial_constants,
        template_metadata: @template_metadata,
        host_tag_metadata: @host_tag_metadata,
      }
    end

    # Reconstruct a Template from cached components (no recompilation needed).
    # Accepts the output of #cache_data.
    #
    #   data = template.cache_data
    #   restored = LiquidIL::Template.from_cache(**data)
    #
    # spans: is accepted and ignored so legacy Marshal cache_data blobs
    # (which include a :spans key) still splat cleanly.
    def self.from_cache(source:, iseq_binary:, partial_constants: nil, template_metadata: nil,
                        host_tag_metadata: nil, spans: nil)
      compiled_proc = RubyVM::InstructionSequence.load_from_binary(iseq_binary).eval
      result = RubyCompiler::CompilationResult.new(
        proc: compiled_proc,
        source: nil,
        can_compile: true,
        partial_constants: partial_constants,
        template_metadata: template_metadata,
        host_tag_metadata: host_tag_metadata,
      )
      new(source, [], nil, result, iseq_binary: iseq_binary)
    end

    # Reconstruct a Template from a raw ISeq binary (the Artifact load path —
    # no source needed: error locations are compile-time literals baked
    # into the emitted code).
    def self.from_iseq_binary(iseq_binary, partial_constants: nil, template_metadata: nil,
                              host_tag_metadata: nil)
      from_cache(source: "", iseq_binary: iseq_binary,
                 partial_constants: partial_constants,
                 template_metadata: template_metadata,
                 host_tag_metadata: host_tag_metadata)
    end

    # Encode this compiled template into the persistable artifact string
    # (see LiquidIL::Artifact for the format and LiquidIL::Artifact.load /
    # LiquidIL.load_artifact for the other side).
    def to_artifact
      Artifact.encode(self)
    end

    # Renderer-owned compile hooks can replace raw captured-tag bodies with a
    # compact, already-processed representation before the artifact is encoded.
    # This does not affect the generated ISeq.
    def transform_template_metadata!
      @template_metadata = yield(@template_metadata) if @template_metadata
      self
    end

    # Build the lightweight renderer object around this template's existing
    # compiled proc. `artifact_bytes` is still published to remote caches, but
    # the compiling process does not need to decode and load its own ISeq just
    # to populate the live-artifact cache.
    def to_compiled_artifact(artifact_bytes = nil)
      artifact_bytes ||= to_artifact
      CompiledArtifact.new(
        @compiled_proc,
        @partial_constants,
        artifact_bytes.bytesize,
        Artifact.identity(artifact_bytes),
        Artifact.external_deps(@partial_dependencies),
        @template_metadata,
        @host_tag_metadata,
      )
    end

    # Render the template with the given variables.
    #
    #   template.render(name: "World")
    #   template.render({ "x" => 1 }, registers: { page_type: "product" })
    #   template.render({ "x" => 1 }, strict_variables: true, strict_filters: true)
    #
    def render(assigns = {}, render_errors: true, registers: nil,
               strict_variables: nil, strict_filters: nil,
               static_environments: nil,
               resource_limits: nil,
               partial_provider: nil,
               output: nil,
               **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = RenderExecutor.build_scope(
        assigns,
        context: @context,
        registers: registers,
        render_errors: render_errors,
        static_environments: static_environments,
        strict_variables: strict_variables,
        strict_filters: strict_filters,
        resource_limits: resource_limits,
        partial_provider: partial_provider,
      )
      RenderExecutor.call(@compiled_proc, scope, @partial_constants, output: output)
    end

    # Strict render — raises on any error instead of rendering inline.
    def render!(assigns = {}, **options)
      render(assigns, render_errors: false, **options)
    end

    # Execute this freshly compiled template against a host-owned Scope.
    # CompiledArtifact exposes the same seam for cache hits; keeping it on
    # Template as well lets hosts use an identical context bridge on compile
    # misses without serializing and reloading the template first.
    def render_scope(scope, output: nil)
      RenderExecutor.call(@compiled_proc, scope, @partial_constants, output: output)
    end

    # Render, appending into a caller-provided String buffer instead of
    # returning a fresh one; returns the buffer. The storefront renderer's
    # contract (renderable_template.rb) expects this shape (a 16KB preallocated
    # buffer per request).
    #
    #   buf = +"<html>"
    #   template.render_to_output_buffer({ "x" => 1 }, buf)  # => buf, extended
    #
    # The compiled proc writes directly into this buffer, avoiding an
    # intermediate full-render String and copy.
    def render_to_output_buffer(context_or_assigns = {}, output = +"", **options)
      render(context_or_assigns, output: output, **options)
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

    # Write compiled ISeq binary directly to disk.
    #
    #   template.write_iseq("template.iseq")
    #
    # For full metadata roundtrip, use #write_cache / .load_cache.
    def write_iseq(filename)
      File.binwrite(filename, iseq_binary)
    end

    # Write the artifact envelope to disk.
    #
    #   template.write_cache("template.ilc")
    #   restored = LiquidIL::Template.load_cache("template.ilc")
    #
    def write_cache(filename)
      File.binwrite(filename, to_artifact)
    end

    # Pretty-print IL instructions (for debugging).
    def dump_il(io = $stdout, color: true)
      PrettyPrinter.new(@instructions, color: color).print(io)
    end

    def il_to_s(color: true)
      PrettyPrinter.new(@instructions, color: color).to_s
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

      # Load a template from a raw ISeq binary file.
      #
      #   t = LiquidIL::Template.load_iseq("template.iseq", source: "Hello {{ name }}")
      #   t.render("name" => "World")
      #
      # spans: is accepted and ignored (legacy callers).
      def load_iseq(filename, source: "", spans: nil, partial_constants: nil)
        from_cache(
          source: source,
          iseq_binary: File.binread(filename),
          partial_constants: partial_constants,
        )
      end

      # Load a template from a cache file written by #write_cache.
      # Accepts both the framed artifact format and legacy Marshal payloads.
      def load_cache(filename)
        Artifact.load(File.binread(filename))
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

        autoload :LiquidIL, "liquid_il" unless defined?(LiquidIL)

        module #{module_name}

          PARTIAL_CONSTANTS = #{@partial_constants.inspect}.freeze

          def self.render(assigns = {}, render_errors: true)
            __scope__ = LiquidIL::Scope.new(assigns)
            __scope__.render_errors = render_errors
            __partial_constants__ = PARTIAL_CONSTANTS

            # Match compiler-generated local names used in proc source.
            _S = __scope__
            _pc = __partial_constants__
            _O = +""

        #{indent_body(proc_body, 4)}

            _O
          rescue LiquidIL::RuntimeError => e
            raise unless render_errors
            output = defined?(_O) ? _O : +""
            location = e.file ? "\#{e.file} line \#{e.line}" : "line \#{e.line}"
            output << "Liquid error (\#{location}): \#{e.message}"
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

    # Load a persisted artifact string into a CompiledArtifact — the fast
    # path for the compile-once → memcache/DB → cold load+render workflow.
    #
    #   artifact = LiquidIL.load_artifact(memcache.get(key))
    #   artifact.render(assigns)
    #
    def load_artifact(blob)
      Artifact.load_compiled(blob)
    end

    # One-shot cold load + render.
    #
    #   LiquidIL.load_and_render(memcache.get(key), assigns)
    #
    def load_and_render(blob, assigns = {}, registers: nil)
      Artifact.load_compiled(blob).render(assigns, registers: registers)
    end
  end
end

require_relative "liquid_il/artifact"
require_relative "liquid_il/template_cache"
require_relative "liquid_il/renderer"
