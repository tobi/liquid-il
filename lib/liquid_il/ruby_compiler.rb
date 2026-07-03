# frozen_string_literal: true

require_relative "runtime_helpers"
require_relative "ruby_compiler/expression_helpers"

module LiquidIL
  # Compiles IL to Ruby with native control flow (if/else, each blocks)
  # and direct expressions (no stack). This generates YJIT-friendly code.
  class RubyCompiler
    include ExpressionHelpers

    OUTPUT_CAPACITY = 8192

    class CompilationResult
      attr_reader :proc, :source, :can_compile, :partials, :partial_constants

      def initialize(proc:, source:, can_compile:, partials: {}, partial_constants: nil)
        @proc = proc
        @source = source
        @can_compile = can_compile
        @partials = partials
        @partial_constants = partial_constants
      end
    end

    # Comparison operator mapping
    COMPARE_OPS = { eq: "==", ne: "!=", lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    # Numeric-only operators that can be inlined (no to_liquid_value needed for simple numeric comparisons)
    NUMERIC_COMPARE_OPS = { lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    # Cached indent strings to avoid repeated "  " * n allocations
    INDENT = Array.new(20) { |i| ("  " * i).freeze }.freeze

    def initialize(instructions, spans: nil, template_source: nil, context: nil, partials: nil, partial_names_in_progress: nil)
      @instructions = instructions
      @spans = spans || []
      @template_source = template_source
      @context = context
      @loop_depth = 0 # Track nested loop depth for parentloop support
      # Compile-time current file (nil for the main template, the partial
      # name inside partial compilations, updated by SET_CONTEXT). Baked into
      # emitted error-location literals — no runtime tracking in the code.
      @current_file_lit = nil
      # Loop-local naming offset. 0 for the main template; partials get a
      # unique base (compile_partial) so their loop locals (__i0__, _fl0__,
      # :loop_break_0, ...) never collide with a call site's when inlined.
      @loop_name_base = 0
      @has_resource_limits = !!context&.resource_limits
      @partials = partials || {}
      @partial_names_in_progress = partial_names_in_progress || Set.new
      @uses_interrupts = detect_uses_interrupts
      # Maps Liquid variable names to Ruby local variable names inside for loops
      # e.g. "i" => "_i0__", "forloop" => "_fl0__"
      @loop_var_aliases = {}
      # Frozen array constants used by THIS compilation: { "[\"large\"]" => "_fa0__" }
      # (names come from the process-wide @@frozen_array_names registry)
      @frozen_arrays = {}
      # Partials that some emitted body actually lambda-calls. Recorded at
      # emission time (and stored with cached bodies) so generate_partial_lambdas
      # emits exactly the lambdas that are needed — no decision re-derivation.
      @lambda_called = Set.new
      # Track which partials are fully inlined (no lambda call sites)
      @inlined_partials = Set.new
      # Pre-built partial spans/source objects — injected via binding at eval time
      @partial_constants = {}
    end

    # Check if template uses break/continue
    def detect_uses_interrupts
      @instructions.any? { |inst| inst[0] == IL::PUSH_INTERRUPT }
    end

    # Calculate line number from PC using spans
    def line_for_pc(pc)
      return 1 unless @spans && @template_source
      span = @spans[pc]
      return 1 unless span
      pos = span[0]
      @template_source[0, pos].count("\n") + 1
    end

    def compile
      # can_compile? / compilation_blockers always returns true/[] — all templates supported
      code = generate_ruby
      compiled_proc = eval_ruby(code)
      raise "Failed to eval generated Ruby code" unless compiled_proc

      CompilationResult.new(
        proc: compiled_proc,
        source: code,
        can_compile: true,
        partial_constants: @partial_constants.empty? ? nil : @partial_constants.freeze,
      )
    end

    # Compile a partial and store it for later code generation
    def compile_partial(name)
      # If already compiled, skip
      if @partials[name] && @partials[name][:compiled_body]
        return
      end

      # Check class-level cache for unchanged partials.
      # A cached body may have nested partial bodies inlined into it, so the
      # hit is only valid when every transitive dependency's source is
      # unchanged too (cached[:deps] maps dep name → source hash).
      source_key = nil
      fs = @context&.file_system
      partial_source = RuntimeHelpers.read_partial_source(fs, name, @context)
      if partial_source
        source_key = partial_source.hash
        if (cached = @@partial_cache[source_key]) && partial_cache_deps_valid?(cached, fs)
          @partials[name] = cached
          # The cached body references frozen-array constants and nested
          # partial lambdas from its original compilation — re-declare the
          # constants, replay its recorded lambda calls, and compile the
          # nested partials in this compilation too.
          adopt_frozen_arrays(cached[:compiled_body])
          @lambda_called.merge(cached[:lambda_called]) if cached[:lambda_called]
          compile_nested_partials(cached[:instructions])
          return
        end
      end

      # Mutual recursion detected — mark as recursive for runtime resolution
      if @partial_names_in_progress.include?(name)
        @partials[name] = { recursive: true }
        return
      end

      @partial_names_in_progress.add(name)

      # Load the partial source
      source = partial_source || RuntimeHelpers.read_partial_source(fs, name, @context)

      unless source
        @partial_names_in_progress.delete(name)
        raise "Cannot load partial '#{name}'"
      end

      # Compile the partial to IL
      begin
        compiler = LiquidIL::Compiler.new(source, optimize: true, skip_passes: [0, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22])
        result = compiler.compile
      rescue LiquidIL::SyntaxError => e
        @partial_names_in_progress.delete(name)
        # Store the syntax error for runtime rendering
        @partials[name] = { syntax_error: e, source: source, name: name }
        return
      end
      instructions = result[:instructions]
      spans = result[:spans]

      # Recursively compile to Ruby (sharing partials cache + frozen arrays)
      ruby_compiler = RubyCompiler.new(
        instructions,
        spans: spans,
        template_source: source,
        context: @context,
        partials: @partials,
        partial_names_in_progress: @partial_names_in_progress
      )
      # Share frozen array usage map so partial constants are declared in the parent proc
      ruby_compiler.instance_variable_set(:@frozen_arrays, @frozen_arrays)
      # Unique loop-naming base per partial source (process-wide, stable for
      # @@partial_cache hits) — prevents loop-local collisions when this
      # body is inlined inside a caller's loop.
      base = (@@partial_loop_bases[source.hash] ||= @@partial_loop_bases.size * 100 + 100)
      ruby_compiler.instance_variable_set(:@loop_name_base, base)
      ruby_compiler.instance_variable_set(:@current_file_lit, name)
      child_lambda_called = Set.new
      ruby_compiler.instance_variable_set(:@lambda_called, child_lambda_called)

      # Check if this partial can be compiled
      unless ruby_compiler.send(:can_compile?)
        @partial_names_in_progress.delete(name)
        raise "Partial '#{name}' cannot be compiled (unsupported features)"
      end

      # Scan for nested partials first (this populates @partials with all nested partials)
      ruby_compiler.send(:scan_and_compile_partials)

      # Generate code for this partial's body
      ruby_compiler.instance_variable_set(:@pc, 0)
      partial_body = ruby_compiler.send(:generate_body)

      # Detect which features this partial uses (for conditional preamble generation)
      partial_uses_cycles = false
      partial_uses_captures = false
      partial_uses_ifchanged = false
      instructions.each do |i|
        case i[0]
        when IL::CYCLE_STEP, IL::CYCLE_STEP_VAR then partial_uses_cycles = true
        when IL::PUSH_CAPTURE then partial_uses_captures = true
        when IL::IFCHANGED_CHECK then partial_uses_ifchanged = true
        when IL::INCLUDE_PARTIAL, IL::RENDER_PARTIAL, IL::CONST_INCLUDE, IL::CONST_RENDER then partial_uses_cycles = true
        end
      end

      @partials[name] = {
        source: source,
        instructions: instructions,
        spans: spans,
        compiled_body: partial_body,
        uses_cycles: partial_uses_cycles,
        uses_captures: partial_uses_captures || partial_uses_ifchanged,
        uses_ifchanged: partial_uses_ifchanged,
        deps: partial_dependency_hashes(instructions),
        lambda_called: child_lambda_called.to_a.freeze
      }
      @lambda_called.merge(child_lambda_called)

      # Cache for next compile of a template using this partial
      if source_key
        @@partial_cache.clear if @@partial_cache.size >= PARTIAL_CACHE_MAX
        @@partial_cache[source_key] = @partials[name].dup
      end

      @partial_names_in_progress.delete(name)
    end

    # Transitive {partial name => source hash} for every static partial this
    # body depends on. Nested bodies can be inlined into this body, so a cache
    # hit is only valid when all of these sources are unchanged.
    def partial_dependency_hashes(instructions)
      deps = {}
      instructions.each do |i|
        next unless i[0] == IL::RENDER_PARTIAL || i[0] == IL::INCLUDE_PARTIAL
        args = i[2] || {}
        next if args["__dynamic_name__"] || args["__invalid_name__"]
        dep = i[1]
        info = @partials[dep]
        next unless info
        deps[dep] = info[:source].hash if info[:source]
        info[:deps]&.each { |k, v| deps[k] ||= v }
      end
      deps
    end

    def partial_cache_deps_valid?(cached, fs)
      deps = cached[:deps]
      return true if deps.nil? || deps.empty?
      deps.all? do |dep_name, source_hash|
        RuntimeHelpers.read_partial_source(fs, dep_name, @context)&.hash == source_hash
      end
    end

    # Re-declare the frozen-array constants a cached body references.
    # Names are globally unique per literal (see register_frozen_array), so a
    # body compiled in an earlier compilation resolves to the same constants.
    def adopt_frozen_arrays(body)
      return unless body
      names = body.scan(/_fa\d+__/)
      return if names.empty?
      inverse = @@frozen_array_names.invert
      names.uniq.each do |constant_name|
        literal = inverse[constant_name]
        @frozen_arrays[literal] = constant_name if literal
      end
    end

    def partial_lambda_name(name)
      "__partial_#{name.gsub(/[^a-zA-Z0-9_]/, '_')}__"
    end

    private

    # Check if we can compile this template
    def can_compile?
      true  # All templates are now supported
    end

    def compilation_blockers
      blockers = []
      has_include = false
      has_for_loop = false

      @instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          args = inst[2] || {}
          # Dynamic/invalid names and missing file system are handled at codegen
          # (they emit inline error messages). Only block on structural issues.
          if !args["__dynamic_name__"] && !args["__invalid_name__"] && @context&.file_system
            has_include = true if inst[0] == IL::INCLUDE_PARTIAL
          end
        when IL::FOR_INIT, IL::TABLEROW_INIT
          has_for_loop = true
        end
      end

      # Include + interrupt propagation is now supported — partials push interrupts
      # to scope, and the caller checks after each include call.

      blockers
    end

    # Check if a partial uses interrupts (break/continue)
    def partial_uses_interrupts?(name, visited = Set.new)
      return false if visited.include?(name)
      visited.add(name)

      fs = @context&.file_system
      return false unless fs

      source = RuntimeHelpers.read_partial_source(fs, name, @context)

      return false unless source

      begin
        result = Compiler.new(source, file_system: fs).compile
        instructions = result[:instructions]

        # Direct interrupt in this partial
        return true if instructions.any? { |inst| inst[0] == IL::PUSH_INTERRUPT }

        # Transitively check included partials
        instructions.each do |inst|
          if inst[0] == IL::INCLUDE_PARTIAL
            child_name = inst[1]
            args = inst[2] || {}
            next if args["__dynamic_name__"] || args["__invalid_name__"]
            return true if partial_uses_interrupts?(child_name, visited)
          end
        end

        false
      rescue
        false
      end
    end

    # Generate Ruby code from IL
    def generate_ruby
      # Scan for partials only (compile them first)
      @uses_cycles = false
      @uses_captures = false
      @uses_ifchanged = false

      @instructions.each do |i|
        case i[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          name = i[1]
          args = i[2] || {}
          next if args["__dynamic_name__"] || args["__invalid_name__"]
          next unless @context&.file_system
          next if @partials[name] && @partials[name][:compiled_body]
          compile_partial(name)
        end
      end
      # After all partials compiled, check if any uses cycles/captures/ifchanged
      @partials.each_value do |info|
        next unless info[:compiled_body]
        @uses_cycles = true if info[:uses_cycles]
        @uses_captures = true if info[:uses_captures]
        @uses_ifchanged = true if info[:uses_ifchanged]
      end

      # Ensure shared helpers are initialized (once, at first use)
      RuntimeHelpers.init

      # Generate body first so inlining info is available for partial lambdas
      body_code = generate_body  # also sets @uses_cycles, @uses_captures, @uses_ifchanged, @inlined_partials
      partial_code = generate_partial_lambdas  # skips lambda body for fully inlined partials

      code = String.new
      has_pc = !@partial_constants.empty?
      code << "# frozen_string_literal: true\n"
      if has_pc
        code << "proc do |_S, _sp, _ts, _pc|\n"
      else
        code << "proc do |_S, _sp, _ts|\n"
      end
      code << "  _H = LiquidIL::RuntimeHelpers\n"
      code << "  _U = LiquidIL::Utils\n" if body_code.include?("_U.") || partial_code.include?("_U.")
      code << "  _F = LiquidIL::Filters\n" if body_code.include?("_F") || partial_code.include?("_F")
      # Frozen array constants must be declared before partial lambdas
      # (lambdas are closures that capture these variables)
      code << generate_frozen_array_constants
      code << partial_code
      code << "  _O = +\"\"\n"
      # Pre-initialize filter caches to avoid ||= check per iteration
      FILTER_CACHE.each_value do |cache_var|
        code << "  #{cache_var} = {}\n" if body_code.include?(cache_var)
      end
      code << "  _cs = {}\n" if @uses_cycles
      code << "  _cst = []\n" if @uses_captures || @uses_ifchanged
      code << "  _ics = {}\n" if @uses_ifchanged
      code << "\n"
      code << optimize_repeated_lookups(body_code)
      code << "\n  _O\n"
      code << "end\n"
      code
    end

    # Scan instructions for partials and compile them
    def scan_and_compile_partials
      compile_nested_partials(@instructions)
    end

    def compile_nested_partials(instructions)
      return unless instructions
      instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          name = inst[1]
          args = inst[2] || {}
          # Skip dynamic/invalid/no-fs partials (handled at codegen)
          next if args["__dynamic_name__"] || args["__invalid_name__"]
          next unless @context&.file_system
          next if @partials[name]
          # compile_partial will raise if mutual recursion detected
          compile_partial(name)
        end
      end
    end

    # Static call sites per partial across this template and all its partials.
    # Drives the inline-vs-lambda size policy: a single-call-site partial
    # inlines (no lambda apparatus), a multi-site partial only inlines while
    # its body is small (duplication cost), otherwise all sites share the
    # runtime-wrapped lambda.
    def call_site_count(name)
      @call_site_counts ||= begin
        counts = Hash.new(0)
        scan = lambda do |instructions|
          instructions&.each do |inst|
            next unless inst[0] == IL::RENDER_PARTIAL || inst[0] == IL::INCLUDE_PARTIAL
            args = inst[2] || {}
            next if args["__dynamic_name__"] || args["__invalid_name__"]
            counts[inst[1]] += 1
          end
        end
        scan.call(@instructions)
        @partials.each_value { |info| scan.call(info[:instructions]) }
        counts
      end
      @call_site_counts[name]
    end

    # Bodies larger than this render via the shared lambda instead of being
    # inlined at every call site. Inlining duplicates the body into each site,
    # bloating the artifact (cold-load cost ~3µs/KB of ISeq); the lambda costs
    # one already-jitted call. Small bodies still inline — the call overhead
    # dominates their size. Deliberately a function of the CALLEE only, so the
    # decision is stable for @@partial_cache-reused bodies.
    INLINE_BODY_MAX_BYTES = 512

    # Check if a partial is safe for inlining (no complex features that need lambda wrapper)
    def partial_inlinable?(name)
      info = @partials[name] || {}
      return false unless info[:compiled_body]
      # Must not use cycles, captures, or ifchanged (these need state in lambda)
      return false if info[:uses_cycles] || info[:uses_captures] || info[:uses_ifchanged]
      # Must not be recursive or have syntax errors
      return false if info[:recursive] || info[:syntax_error]
      true
    end

    # Generate lambda definitions for compiled partials
    def generate_partial_lambdas
      return "" if @partials.empty?

      required = @lambda_called

      code = String.new
      code << "\n  # Compiled partial lambdas\n"
      # Forward-declare all lambda variables so mutual references work
      @partials.each do |name, info|
        next if info[:recursive] || info[:syntax_error]
        code << "  #{partial_lambda_name(name)} = nil\n"
      end
      code << "\n"

      @partials.each do |name, info|
        next if info[:recursive] || info[:syntax_error] || !info[:compiled_body]
        # Emit the lambda body only when some call site actually calls it
        # (a partial can be inlined at one site and lambda-called at another).
        # The forward declaration (nil) is already generated above.
        next unless required.include?(name)
        lambda_name = partial_lambda_name(name)
        # All prologue/rescue/ensure bookkeeping lives in the (already-jitted)
        # runtime helper _H.ip — zero artifact bytes per lambda for it.
        # Error locations inside the body are compile-time literals, so the
        # lambda carries no spans/source/current-file state.
        code << "  #{lambda_name} = ->(assigns, _O, __parent_scope__, isolated, caller_line: 1, parent_cycle_state: nil) {\n"
        code << "    _H.ip(#{name.inspect}, __parent_scope__, isolated, caller_line, _O) {\n"
        code << "      __partial_scope__ = isolated ? __parent_scope__.isolated_with(assigns) : __parent_scope__\n"
        # Only allocate cycle/capture/ifchanged state when the partial actually uses them
        if info[:uses_cycles]
          code << "      _cs = isolated ? {} : (parent_cycle_state || {})\n"
        end
        if info[:uses_captures]
          code << "      _cst = []\n"
        end
        if info[:uses_ifchanged]
          code << "      _ics = {}\n"
        end
        code << indent_partial_body(info[:compiled_body], 6)
        code << "    }\n"
        code << "  }\n\n"
      end
      code
    end

    # Cache for indented partial body with assign key replacements
    @@indent_partial_body_cache = {}

    def indent_partial_body(body, spaces, assign_keys: [], arg_expressions: nil)
      indent = " " * spaces
      cache_key = [body.hash, assign_keys.sort, spaces, arg_expressions&.hash]
      return @@indent_partial_body_cache[cache_key] if @@indent_partial_body_cache.key?(cache_key)

      # Replace _S with __partial_scope__ to avoid closure issues
      body = body.gsub("_S", "__partial_scope__")
      # For inlined isolated partials, replace __partial_scope__.lookup(key) with direct access
      if arg_expressions
        # Use temp variables instead of __partial_args__ hash — eliminates hash overhead
        assign_keys.each do |key|
          if arg_expressions[key]
            temp_var = "__p_#{key}__"
            # For constant String args, skip .to_s (String#to_s returns self)
            is_const_string = arg_expressions[key].is_a?(String) && arg_expressions[key] =~ /\A".*"\z/
            if is_const_string
              body = body.gsub("_H.oa(_O, __partial_args__[#{key.inspect}])", "_O << #{temp_var}")
              body = body.gsub("_H.oa(_O, __partial_scope__.lookup(#{key.inspect}))", "_O << #{temp_var}")
            else
              # Inline .to_s for oa calls with temp variables (avoids method dispatch)
              body = body.gsub("_H.oa(_O, __partial_args__[#{key.inspect}])", "_O << (#{temp_var}.to_s)")
              body = body.gsub("_H.oa(_O, __partial_scope__.lookup(#{key.inspect}))", "_O << (#{temp_var}.to_s)")
            end
            body = body.gsub("__partial_args__[#{key.inspect}]", temp_var)
            body = body.gsub("__partial_scope__.lookup(#{key.inspect})", temp_var)
          end
        end
      elsif assign_keys.length > 0
        assign_keys.each do |key|
          body = body.gsub("__partial_scope__.lookup(#{key.inspect})", "__partial_args__[#{key.inspect}]")
        end
      end
      result = body.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l}" }.join
      @@indent_partial_body_cache[cache_key] = result
    end

    # Generate the template body
    def generate_body
      @pc = 0
      code = String.new
      instructions = @instructions
      len = instructions.length
      interrupt = @uses_interrupts

      while @pc < len
        inst = instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::HALT
          @pc += 1
          break
        when IL::WRITE_RAW
          # Merge consecutive WRITE_RAW instructions into single append.
          # Dup before appending — inst[1] may be frozen (custom passthrough
          # tags) and mutating it in place would corrupt @instructions.
          merged = inst[1]
          while (@pc + 1) < len && instructions[@pc + 1][0] == IL::WRITE_RAW
            merged = merged.dup if merged.equal?(inst[1])
            @pc += 1
            merged << instructions[@pc][1]
          end
          @pc += 1
          if interrupt
            code << "  _O << " << merged.inspect << " unless _S.has_interrupt?\n"
          else
            code << "  _O << " << merged.inspect << "\n"
          end
        when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_SELF
          # Needs peek - delegate to generate_statement
          result = generate_statement(1)
          break if result.nil?
          code << result
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          isolated = inst[0] == IL::RENDER_PARTIAL
          code << generate_partial_call(inst, @pc, 1, isolated: isolated)
        when IL::ASSIGN_LOCAL
          @pc += 1
          code << "  _S.assign_local(#{inst[1].inspect}, _S.lookup(#{inst[2].inspect}))\n"
        when IL::IS_TRUTHY
          @pc += 1
          code << "  _S.to_liquid_value("
          code << inst[1]
          code << ").is_truthy?\n"
        when IL::JUMP_IF_INTERRUPT
          @pc += 1
          code << "  next if _S.has_interrupt?\n"
        when IL::POP_INTERRUPT
          @pc += 1
          # no-op in Ruby compiler
        when IL::JUMP
          target = inst[1]
          # Forward jump: skip dead code, continue at target
          # Backward jump: loop-back, handled by loop structure (no-op)
          @pc = target > @pc ? target : @pc + 1
        when IL::PUSH_SCOPE
          @pc += 1
          code << "  _S.push_scope\n"
        when IL::POP_SCOPE
          @pc += 1
          code << "  _S.pop_scope\n"
        when IL::FOR_INIT
          @pc += 1
          code << "  __for_#{inst[2]}__ = _H.wrap_for_loop(#{generate_var_lookup(inst[1])}, "
          code << "has_limit: #{inst[3]}, has_offset: #{inst[4]})\n"
        when IL::FOR_NEXT
          @pc += 1
          code << "  __for_continue__ = false\n"
        when IL::FOR_END
          @pc += 1
          code << "  end\n"
        when IL::PUSH_FORLOOP
          @pc += 1
          code << "  _S.push_forloop(__for_#{inst[1]}__)\n"
        when IL::POP_FORLOOP
          @pc += 1
          code << "  _S.pop_forloop\n"
        when IL::JUMP_IF_EMPTY
          @pc += 1
          code << "  next if _S.empty?(#{generate_var_lookup(inst[1])})\n"
        when IL::COMPARE
          @pc += 1
          code << "  _S.compare(#{inst[1]}, #{inst[2]}, #{inst[3].inspect})\n"
        when IL::CALL_FILTER
          @pc += 1
          code << "_H.call_filter(#{inst[1].inspect}, "
          args_code = inst[2].map { |a| a.inspect }.join(", ")
          code << args_code << ")\n"
        when IL::WRITE_VALUE
          @pc += 1
          code << "  _O << " << inst[1]
          if interrupt
            code << " unless _S.has_interrupt?\n"
          else
            code << "\n"
          end
        else
          # Detect feature flags during codegen (avoids separate scan pass)
          case inst[0]
          when IL::CYCLE_STEP, IL::CYCLE_STEP_VAR, IL::CONST_INCLUDE, IL::CONST_RENDER
            @uses_cycles = true
          when IL::PUSH_CAPTURE
            @uses_captures = true
          when IL::IFCHANGED_CHECK
            @uses_ifchanged = true
          end
          # Complex cases or unrecognized - delegate
          result = generate_statement(1)
          break if result.nil?
          code << result
        end
      end

      code
    end

    # Generate a single statement, returns Ruby code string
    def generate_statement(indent)
      return nil if @pc >= @instructions.length

      inst = @instructions[@pc]
      return nil if inst.nil?

      prefix = INDENT[indent]

      case inst[0]
      when IL::HALT
        @pc += 1
        nil

      when IL::SET_CONTEXT
        # Current file is compile-time state: later emissions bake it into
        # error-location literals. No runtime assignment needed.
        @pc += 1
        @current_file_lit = inst[1]
        ""

      when IL::WRITE_RAW
        @pc += 1
        if @uses_interrupts
          %(#{prefix}_O << #{inst[1].inspect} unless _S.has_interrupt?\n)
        else
          %(#{prefix}_O << #{inst[1].inspect}\n)
        end

      when IL::WRITE_VAR
        @pc += 1
        var_expr = if (alias_var = @loop_var_aliases[inst[1]])
                     alias_var
                   else
                     "_S.lookup(#{inst[1].inspect})"
                   end
        inline_output_append(var_expr, prefix, guard_interrupt: @uses_interrupts)

      when IL::WRITE_VAR_PATH
        @pc += 1
        var_expr = generate_var_path_expr(inst[1], inst[2])
        inline_output_append(var_expr, prefix, guard_interrupt: @uses_interrupts)

      when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_SELF
        if peek_for_loop?
          generate_for_loop(indent)
        elsif peek_tablerow?
          generate_tablerow(indent)
        elsif peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
           IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK
        if peek_for_loop?
          generate_for_loop(indent)
        elsif peek_tablerow?
          generate_tablerow(indent)
        elsif peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE
        generate_if_statement(indent)

      when IL::FOR_INIT
        generate_for_loop_body(nil, nil, indent)

      when IL::TABLEROW_INIT
        # Tablerow at current position means collection already consumed
        generate_tablerow_body(nil, nil, nil, nil, nil, nil, nil, nil, nil, indent)

      when IL::JUMP
        target = inst[1]
        # Only follow forward jumps to avoid infinite loops
        # Backward jumps are loop-back instructions handled by for_loop
        if target > @pc
          @pc = target
          generate_statement(indent)
        else
          # Backward jump - skip it (handled by loop structure)
          @pc += 1
          ""
        end

      when IL::ASSIGN
        @pc += 1
        # Need to look back for the expression
        "#{prefix}# assign #{inst[1]} (complex)\n"

      when IL::ASSIGN_LOCAL
        @pc += 1
        "#{prefix}# assign_local #{inst[1]} (complex)\n"

      when IL::INCREMENT
        @pc += 1
        var = inst[1]
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Use scope's increment - it handles counter independence and proper lookup integration
        "#{prefix}_O << _S.increment(#{var.inspect}).to_s\n"

      when IL::DECREMENT
        @pc += 1
        var = inst[1]
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Use scope's decrement - it handles counter independence and proper lookup integration
        "#{prefix}_O << _S.decrement(#{var.inspect}).to_s\n"

      when IL::PUSH_SCOPE
        @pc += 1
        "#{prefix}_S.push_scope\n"

      when IL::POP_SCOPE
        @pc += 1
        "#{prefix}_S.pop_scope\n"

      when IL::PUSH_CAPTURE
        @uses_captures = true
        @pc += 1
        "#{prefix}_cst << _O; _O = String.new\n"

      when IL::POP_CAPTURE
        @pc += 1
        # POP_CAPTURE pushes captured value onto stack, followed by ASSIGN or IFCHANGED_CHECK
        # Peek ahead to determine what follows
        if @instructions[@pc]&.[](0) == IL::ASSIGN
          var = @instructions[@pc][1]
          @pc += 1
          "#{prefix}__captured__ = _O; _O = _cst.pop; _S.assign(#{var.inspect}, __captured__)\n"
        elsif @instructions[@pc]&.[](0) == IL::IFCHANGED_CHECK
          @uses_ifchanged = true
          tag_id = @instructions[@pc][1]
          @pc += 1
          # ifchanged: output captured content only if it differs from previous
          code = String.new
          code << "#{prefix}__captured__ = _O; _O = _cst.pop\n"
          code << "#{prefix}if __captured__ != _ics[#{tag_id.inspect}]\n"
          code << "#{prefix}  _ics[#{tag_id.inspect}] = __captured__\n"
          code << "#{prefix}  _O << __captured__\n"
          code << "#{prefix}end\n"
          code
        else
          # Fallback - just restore output (captured value is lost)
          "#{prefix}_O = _cst.pop\n"
        end

      when IL::CYCLE_STEP
        @uses_cycles = true
        @pc += 1
        identity = inst[1]
        raw_values = inst[2]
        # Extract actual values from tuples, handle both literals and variables
        # [:lit, value] -> literal value
        # [:var, name] -> runtime variable lookup
        values_ruby = raw_values.map do |v|
          if v.is_a?(Array)
            case v[0]
            when :lit then v[1].inspect
            when :var then "_S.lookup(#{v[1].inspect})"
            else v.inspect
            end
          else
            v.inspect
          end
        end
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Use __cycle_idx__ to avoid conflict with _x_ in for loops
        # Handle empty values: cycle with 0 choices outputs nothing (empty string)
        if raw_values.empty?
          "#{prefix}_cs[#{identity.inspect}] = (_cs[#{identity.inspect}] || 0) + 1\n"
        else
          "#{prefix}__cycle_idx__ = _cs[#{identity.inspect}] ||= 0; _O << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; _cs[#{identity.inspect}] = __cycle_idx__ + 1\n"
        end

      when IL::CYCLE_STEP_VAR
        @uses_cycles = true
        @pc += 1
        var_name = inst[1]
        raw_values = inst[2]
        # Extract actual values from tuples
        values_ruby = raw_values.map do |v|
          if v.is_a?(Array)
            case v[0]
            when :lit then v[1].inspect
            when :var then "_S.lookup(#{v[1].inspect})"
            else v.inspect
            end
          else
            v.inspect
          end
        end
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Identity is a variable - look it up at runtime
        # Handle empty values: cycle with 0 choices outputs nothing (empty string)
        if raw_values.empty?
          "#{prefix}__cycle_key__ = _S.lookup(#{var_name.inspect}); _cs[__cycle_key__] = (_cs[__cycle_key__] || 0) + 1\n"
        else
          "#{prefix}__cycle_key__ = _S.lookup(#{var_name.inspect}); __cycle_idx__ = _cs[__cycle_key__] ||= 0; _O << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; _cs[__cycle_key__] = __cycle_idx__ + 1\n"
        end

      when IL::PUSH_INTERRUPT
        # Break/continue: translate to Ruby control flow
        # We use throw/catch for break (to avoid LocalJumpError in nested blocks)
        # and Ruby's next for continue (works inside each blocks)
        interrupt_type = inst[1]
        @pc += 1

        code = String.new

        # If break/continue is followed by POP_CAPTURE + ASSIGN, we need to handle
        # capture cleanup. When inside a loop, complete the assignment BEFORE throwing.
        # When outside a loop, just restore output without assigning (discard capture).
        if @instructions[@pc]&.[](0) == IL::POP_CAPTURE &&
           @instructions[@pc + 1]&.[](0) == IL::ASSIGN
          var = @instructions[@pc + 1][1]
          @pc += 2 # Consume POP_CAPTURE and ASSIGN
          if @loop_depth > 0
            # Inside loop: complete the capture assignment before breaking
            code << "#{prefix}__captured__ = _O; _O = _cst.pop; _S.assign(#{var.inspect}, __captured__)\n"
          else
            # Outside loop: just restore output, discard captured content
            code << "#{prefix}_O = _cst.pop\n"
          end
        end

        if @loop_depth > 0
          if interrupt_type == :break
            # Use throw to exit the current loop - depth-1 because we're inside the loop
            code << "#{prefix}throw(:loop_break_#{@loop_name_base + @loop_depth - 1})\n"
          else
            code << "#{prefix}next\n"
          end
        else
          # Break/continue outside of loop - push interrupt to scope to stop further output
          code << "#{prefix}_S.push_interrupt(#{interrupt_type.inspect})\n"
        end

        code

      when IL::LABEL, IL::POP_INTERRUPT, IL::JUMP_IF_INTERRUPT, IL::POP_FORLOOP,
           IL::FOR_END, IL::FOR_NEXT, IL::JUMP_IF_EMPTY, IL::PUSH_FORLOOP, IL::POP,
           IL::IFCHANGED_CHECK, IL::TABLEROW_NEXT, IL::TABLEROW_END
        @pc += 1
        "" # No-ops in generated Ruby (IFCHANGED_CHECK handled by POP_CAPTURE)

      when IL::LOAD_TEMP
        # Load from temp generates expression - peek ahead to see what follows
        if peek_for_loop?
          generate_for_loop(indent)
        elsif peek_tablerow?
          generate_tablerow(indent)
        elsif peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::RENDER_PARTIAL
        generate_partial_call(inst, @pc, indent, isolated: true)

      when IL::INCLUDE_PARTIAL
        generate_partial_call(inst, @pc, indent, isolated: false)

      when :PAGINATE_SETUP
        @pc += 1
        coll_path = inst[1]
        page_size = inst[2]
        prefix = INDENT[indent]
        # Generate runtime paginate setup using helper method
        parts = coll_path.split(".")
        lookup = "_S.lookup(#{parts[0].inspect})"
        parts[1..].each { |p| lookup = "_H.l(#{lookup}, #{p.inspect})" }
        code = String.new
        code << "#{prefix}_pc = #{lookup}\n"
        code << "#{prefix}_pc = _pc.respond_to?(:to_a) ? _pc.to_a : Array(_pc) unless _pc.is_a?(Array)\n"
        code << "#{prefix}_pg, _pi2 = _H.build_paginate(_pc, #{page_size}, (_S.lookup('current_page') || 1).to_i)\n"
        code << "#{prefix}_S.assign('paginate', _pg)\n"
        code << "#{prefix}_S.assign(#{parts.last.inspect}, _pi2)\n" if parts.length == 1
        code

      when :PAGINATE_TEARDOWN
        @pc += 1
        ""

      else
        generate_expression_statement(indent)
      end
    end

    # Build expression until we hit STORE_TEMP
    # Generate an expression statement (expression followed by WRITE_VALUE or ASSIGN)
    def generate_expression_statement(indent)
      prefix = INDENT[indent]
      @temp_assignments = nil

      # build_expression now returns Ruby string directly (not Expr)
      expr_ruby, terminator = build_expression

      return nil if expr_ruby.nil?

      temp_code = String.new
      if @temp_assignments
        @temp_assignments.each do |slot, temp_ruby|
          temp_code << "#{prefix}__temp_#{slot}__ = #{temp_ruby}\n"
        end
        @temp_assignments = nil
      end

      case terminator
      when :write_value
        temp_code + inline_output_append(expr_ruby, prefix, guard_interrupt: @uses_interrupts)
      when :assign
        var = @instructions[@pc - 1][1]
        temp_code + "#{prefix}_v = #{expr_ruby}; _S.assign(#{var.inspect}, _v) unless _v.is_a?(LiquidIL::ErrorMarker)\n"
      when :assign_local
        var = @instructions[@pc - 1][1]
        temp_code + "#{prefix}_v = #{expr_ruby}; _S.assign_local(#{var.inspect}, _v) unless _v.is_a?(LiquidIL::ErrorMarker)\n"
      when :store_temp
        slot = @instructions[@pc][1]
        @pc += 1
        temp_code + "#{prefix}__temp_#{slot}__ = #{expr_ruby}\n"
      when :condition
        @pc -= 1
        nil
      else
        temp_code + "#{prefix}#{expr_ruby}\n"
      end
    end

    # ── Codegen security invariant ──────────────────────────────
    # All template-derived strings (partial names, tag types, lookup
    # keys, etc.) must be emitted into generated Ruby source ONLY through
    # `lit` (for string literals) or `comment_safe` (for comments).
    # Raw interpolation of template values into emitted code is prohibited
    # — it is an RCE primitive (a malicious name like `evil#{pwn}name`
    # would execute `pwn` at render time). See test/code_injection_test.rb.

    # Emit a template-derived string as a safe Ruby string literal.
    # This is the single codegen primitive for string-literal emission.
    def lit(str)
      str.to_s.inspect
    end

    # Escape a template-derived string for safe embedding in a generated
    # Ruby comment. Comments are newline-terminated, so only newlines
    # need escaping to prevent breaking out of the comment.
    def comment_safe(str)
      str.to_s.gsub("\n", "\\n")
    end

    # Generate a partial call (render or include)
    def generate_partial_call(inst, pc, indent, isolated:)
      @pc += 1
      prefix = INDENT[indent]
      name = inst[1]
      # Cycle state suffix: only include if any partial uses cycles
      @partial_call_cycle_suffix ||= @uses_cycles ? ", parent_cycle_state: _cs" : ""
      args = inst[2] || {}
      tag_type = isolated ? "render" : "include"
      line_num = line_for_pc(pc)

      # Handle invalid/dynamic partial names — emit inline error
      if args["__invalid_name__"]
        return "#{prefix}# #{tag_type} with invalid name\n" \
               "#{prefix}_O << #{lit("Liquid error (line #{line_num}): Argument error in tag '#{tag_type}' - Illegal template name")}\n"
      end
      if args["__dynamic_name__"]
        return generate_dynamic_partial(inst, pc, indent, isolated: isolated)
      end
      if !@context&.file_system
        return "#{prefix}# #{tag_type} '#{comment_safe(name)}' (no file system)\n" \
               "#{prefix}_O << #{lit("Liquid error (line #{line_num}): Could not find partial '#{name}'")}\n"
      end

      # Syntax error in partial — use dynamic execution to surface the error
      if @partials[name]&.[](:syntax_error)
        code = String.new
        code << "#{prefix}# #{tag_type} '#{comment_safe(name)}' (syntax error)\n"
        code << "#{prefix}__dyn_assigns__ = {}\n"
        code << "#{prefix}_H.execute_dynamic_partial(#{name.inspect}, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        return code
      end

      # Recursive partials use runtime resolution
      if @partials[name]&.[](:recursive)
        code = String.new
        code << "#{prefix}# #{tag_type} '#{comment_safe(name)}' (recursive — runtime resolution)\n"
        code << "#{prefix}__dyn_assigns__ = {}\n"
        args.each do |k, v|
          next if k.start_with?("__")
          if v.is_a?(Hash) && v[:__var__]
            code << "#{prefix}__dyn_assigns__[#{k.inspect}] = #{generate_var_lookup(v[:__var__])}\n"
          else
            code << "#{prefix}__dyn_assigns__[#{k.inspect}] = #{v.inspect}\n"
          end
        end
        if (with_expr = args["__with__"])
          as_alias = args["__as__"] || name
          code << "#{prefix}__dyn_assigns__[#{as_alias.inspect}] = #{generate_var_lookup(with_expr)}\n"
        end
        code << "#{prefix}_H.execute_dynamic_partial(#{name.inspect}, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        @pc = @pc  # Already incremented
        return code
      end

      lambda_name = partial_lambda_name(name)
      code = String.new
      code << "#{prefix}# #{tag_type} '#{comment_safe(name)}'\n"

      # Handle with/for expressions
      with_expr = args["__with__"]
      for_expr = args["__for__"]
      as_alias = args["__as__"]
      item_var = as_alias || name

      # Inline policy: single-call-site partials always inline; multi-site
      # partials inline only while the body is small enough that duplication
      # beats the shared lambda (artifact-size policy, see INLINE_BODY_MAX_BYTES).
      inline_partial = isolated && !for_expr && !with_expr && partial_inlinable?(name) &&
        (call_site_count(name) <= 1 || @partials[name][:compiled_body].bytesize <= INLINE_BODY_MAX_BYTES)
      @lambda_called << name unless inline_partial

      # Handle include being disabled inside render context
      unless isolated
        code << "#{prefix}if _S.disable_include\n"
        code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"include usage is not allowed in this context\", file: #{@current_file_lit.inspect}, line: #{line_num})\n"
        code << "#{prefix}else\n"
        prefix = "  " * (indent + 1)
      end

      # Build argument setup code
      # For inlined partials, use temp variables instead of __partial_args__ hash
      # IMPORTANT: For include, lookup with_expr value BEFORE processing keyword args!
      if with_expr && !isolated
        expr = generate_var_lookup(with_expr)
        code << "#{prefix}__with_val__ = #{expr}\n"
      end

      if inline_partial
        @inlined_partials << name
        # Collect arg expressions for inlining with temp variables
        arg_expressions = {}
        args.each do |k, v|
          next if k.start_with?("__")
          if v.is_a?(Hash) && v[:__var__]
            var_path = v[:__var__]
            arg_expressions[k] = var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path)
          else
            arg_expressions[k] = v.inspect
          end
        end
      else
        code << "#{prefix}__partial_args__ = {}\n"
        # Regular named arguments
        args.each do |k, v|
          next if k.start_with?("__")
          if v.is_a?(Hash) && v[:__var__]
            var_path = v[:__var__]
            expr = var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path)
            code << "#{prefix}__partial_args__[#{k.inspect}] = #{expr}\n"
            # For include, also assign to current scope
            unless isolated
              code << "#{prefix}_S.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
            end
          else
            code << "#{prefix}__partial_args__[#{k.inspect}] = #{v.inspect}\n"
            unless isolated
              code << "#{prefix}_S.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
            end
          end
        end
      end

      if for_expr
        # Render once per item in collection
        # IMPORTANT: For include (non-isolated), ranges should NOT be iterated over - they're passed directly.
        # Only arrays are iterated for include. For render (isolated), ranges ARE iterated.
        expr = generate_var_lookup(for_expr)
        code << "#{prefix}__for_coll__ = #{expr}\n"
        code << "#{prefix}if __for_coll__.is_a?(Array)\n"
        code << "#{prefix}  __for_coll__.each_with_index do |_i_, _x_|\n"
        code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
        unless isolated
          code << "#{prefix}    _S.assign(#{item_var.inspect}, _i_)\n"
        end
        if isolated
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __for_coll__.length).tap { |f| f.index0 = _x_ }\n"
        end
        code << "#{prefix}    #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
        # Break out of include-for iteration if partial set interrupt
        unless isolated
          code << "#{prefix}    break if _S.has_interrupt?\n"
        end
        code << "#{prefix}  end\n"
        if isolated
          # render iterates over ranges
          code << "#{prefix}elsif __for_coll__.is_a?(LiquidIL::RangeValue) || __for_coll__.is_a?(Range)\n"
          code << "#{prefix}  __items__ = __for_coll__.to_a\n"
          code << "#{prefix}  __items__.each_with_index do |_i_, _x_|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = _x_ }\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
          code << "#{prefix}  end\n"
          # Also handle other enumerables for render
          code << "#{prefix}elsif !__for_coll__.is_a?(Hash) && !__for_coll__.is_a?(String) && __for_coll__.respond_to?(:each) && __for_coll__.respond_to?(:to_a)\n"
          code << "#{prefix}  __items__ = __for_coll__.to_a\n"
          code << "#{prefix}  __items__.each_with_index do |_i_, _x_|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = _x_ }\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
          code << "#{prefix}  end\n"
        end
        code << "#{prefix}elsif __for_coll__.nil?\n"
        code << "#{prefix}  #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
        code << "#{prefix}else\n"
        code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __for_coll__\n"
        unless isolated
          code << "#{prefix}  _S.assign(#{item_var.inspect}, __for_coll__)\n"
        end
        code << "#{prefix}  #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
        code << "#{prefix}end\n"
      elsif with_expr
        # Render with a specific value
        # For isolated (render), we lookup here. For include, we already looked up above.
        if isolated
          expr = generate_var_lookup(with_expr)
          code << "#{prefix}__with_val__ = #{expr}\n"
          code << "#{prefix}__partial_args__[#{item_var.inspect}] = __with_val__ unless __with_val__.nil?\n"
          code << "#{prefix}#{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
        else
          # For include, __with_val__ was already looked up BEFORE keyword args modified scope
          # Assign the with-value to the current scope so the partial can see it
          code << "#{prefix}if __with_val__.is_a?(Array)\n"
          code << "#{prefix}  __with_val__.each do |_i_|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
          code << "#{prefix}    _S.assign(#{item_var.inspect}, _i_)\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
          code << "#{prefix}  end\n"
          code << "#{prefix}else\n"
          code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __with_val__\n"
          code << "#{prefix}  _S.assign(#{item_var.inspect}, __with_val__)\n"
          code << "#{prefix}  #{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
          code << "#{prefix}end\n"
        end
      else
        # Simple render
        # For simple isolated partials, inline the body to avoid lambda call overhead
        if inline_partial
          info = @partials[name]
          # Generate temp variables for each arg (arg_expressions already built above)
          # Only generate for args that are actually referenced in the partial body
          assign_keys = arg_expressions.keys.select do |k|
            # Check original body patterns (before _S -> __partial_scope__ substitution)
            info[:compiled_body].include?("_S.lookup(#{k.inspect})") ||
              info[:compiled_body].include?("__partial_scope__.lookup(#{k.inspect})")
          end
          arg_expressions.each do |k, expr|
            next unless assign_keys.include?(k)
            code << "#{prefix}__p_#{k}__ = #{expr}\n"
          end
          indented_body = indent_partial_body(info[:compiled_body], indent + 1, assign_keys: assign_keys, arg_expressions: arg_expressions)
          # Need __partial_args__ hash for __partial_scope__ creation
          if indented_body.include?("__partial_scope__")
            code << "#{prefix}__partial_args__ = {}\n"
            assign_keys.each do |k|
              code << "#{prefix}__partial_args__[#{k.inspect}] = __p_#{k}__\n"
            end
            code << "#{prefix}__partial_scope__ = _S.isolated_with(__partial_args__)\n"
          end
          code << indented_body
        else
          code << "#{prefix}#{lambda_name}.call(__partial_args__, _O, _S, #{isolated}, caller_line: #{line_num}#{@partial_call_cycle_suffix})\n"
        end
      end

      # After include: propagate interrupts (break/continue) from partial to caller's loop
      if !isolated && @loop_depth > 0
        code << "#{prefix}if _S.has_interrupt?\n"
        code << "#{prefix}  throw(:loop_break_#{@loop_name_base + @loop_depth - 1}) if _S.pop_interrupt == :break\n"
        code << "#{prefix}  next\n"
        code << "#{prefix}end\n"
      end

      # Close the include disable check
      unless isolated
        code << "  " * indent << "end\n"
      end

      code
    end

    # Generate code for dynamic partial (name from variable)
    def generate_dynamic_partial(inst, pc, indent, isolated:)
      prefix = INDENT[indent]
      args = inst[2] || {}
      tag_type = isolated ? "render" : "include"
      line_num = line_for_pc(pc)

      # The partial name comes from a runtime expression/variable.
      dyn_var = args["__dynamic_name__"] || inst[1]

      code = String.new
      code << "#{prefix}__dyn_name__ = #{generate_var_lookup(dyn_var)}\n"

      # Build assigns hash from args
      code << "#{prefix}__dyn_assigns__ = {}\n"
      args.each do |k, v|
        next if k.start_with?("__")
        if v.is_a?(Hash) && v[:__var__]
          code << "#{prefix}__dyn_assigns__[#{k.inspect}] = #{generate_var_lookup(v[:__var__])}\n"
        else
          code << "#{prefix}__dyn_assigns__[#{k.inspect}] = #{v.inspect}\n"
        end
      end

      # Handle 'with' clause for include
      for_expr = args["__for__"]
      with_expr = args["__with__"]
      as_alias = args["__as__"]

      interrupt_check = ""
      unless isolated || @loop_depth <= 0
        interrupt_check = "#{prefix}    if _S.has_interrupt?\n" \
          "#{prefix}      throw(:loop_break_#{@loop_name_base + @loop_depth - 1}) if _S.pop_interrupt == :break\n" \
          "#{prefix}      next\n" \
          "#{prefix}    end\n"
      end

      if for_expr
        # for clause: iterate over collection, render partial once per item
        expr = generate_var_lookup(for_expr)
        item_var_expr = as_alias ? as_alias.inspect : "__dyn_name__"
        code << "#{prefix}__for_coll__ = #{expr}\n"
        code << "#{prefix}if __for_coll__.is_a?(Array)\n"
        code << "#{prefix}  __for_coll__.each do |_i_|\n"
        code << "#{prefix}    __dyn_assigns__[#{item_var_expr}] = _i_\n"
        code << "#{prefix}    _H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
        code << "#{prefix}  end\n"
        code << "#{prefix}else\n"
        code << "#{prefix}  __dyn_assigns__[#{item_var_expr}] = __for_coll__\n"
        code << "#{prefix}  _H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
        code << "#{prefix}end\n"
      elsif with_expr
        # with clause: pass value (iterate if array for include)
        expr = generate_var_lookup(with_expr)
        item_var_expr = as_alias ? as_alias.inspect : "__dyn_name__"
        code << "#{prefix}__with_val__ = #{expr}\n"
        unless isolated
          # For include, arrays iterate
          code << "#{prefix}if __with_val__.is_a?(Array)\n"
          code << "#{prefix}  __with_val__.each do |_i_|\n"
          code << "#{prefix}    __dyn_assigns__[#{item_var_expr}] = _i_\n"
          code << "#{prefix}    _H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
          code << "#{prefix}  end\n"
          code << "#{prefix}else\n"
          code << "#{prefix}  __dyn_assigns__[#{item_var_expr}] = __with_val__\n"
          code << "#{prefix}  _H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
          code << "#{prefix}end\n"
        else
          code << "#{prefix}__dyn_assigns__[#{item_var_expr}] = __with_val__\n"
          code << "#{prefix}_H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
        end
      else
        code << "#{prefix}_H.execute_dynamic_partial(__dyn_name__, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
        code << interrupt_check
      end

      unless isolated
        # For include, also assign partial args to current scope
        args.each do |k, v|
          next if k.start_with?("__")
          code << "#{prefix}_S.assign(#{k.inspect}, __dyn_assigns__[#{k.inspect}])\n"
        end
      end

      code
    end

    # Generate variable lookup expression
    def generate_var_lookup(expr)
      return "nil" unless expr
      expr_str = expr.to_s

      # Handle string literals
      if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
        return Regexp.last_match(1).inspect
      end

      # Handle range literals
      if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
        return "LiquidIL::RangeValue.new(#{Regexp.last_match(1)}, #{Regexp.last_match(2)})"
      end

      # Parse variable path
      parts = expr_str.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
      return "nil" if parts.empty?

      if parts.size == 1
        first_var = parts[0][0]
        # Use loop variable alias if available (avoids _S.lookup method call)
        if @loop_var_aliases[first_var]
          @loop_var_aliases[first_var]
        else
          "_S.lookup(#{first_var.inspect})"
        end
      else
        first_var = parts[0][0]
        rest_keys = parts[1..].map do |match|
          key = match[0] || match[1] || match[2]
          key.to_s =~ /^\d+$/ ? key.to_i : key.inspect
        end
        raw_rest_keys = parts[1..].map { |m| (m[0] || m[1] || m[2]).to_s }
        # Use loop variable alias if available
        result = if @loop_var_aliases[first_var]
          @loop_var_aliases[first_var]
        else
          "_S.lookup(#{first_var.inspect})"
        end
        if @loop_var_aliases[first_var]
          # Loop variable is always a Hash — inline lookup for speed
          # Skip symbol fallback since loop variables always use string keys
          if rest_keys.size == 1
            key = rest_keys[0]
            result = key.is_a?(String) ? "#{result}[#{key}]" : "#{result}[#{key}]"
          else
            result = "_H.lh(#{result}, #{rest_keys[0]})"
            rest_keys[1..].each { |k| result = "_H.lookup(#{result}, #{k})" }
          end
        else
          rest_keys.each { |k| result = "_H.lookup(#{result}, #{k})" }
        end
        result
      end
    end

    # Build a Ruby expression directly from IL instructions.
    # Returns [ruby_source, terminator_type].
    def build_expression
      # Stack of Ruby strings — avoids allocating a second expression tree.
      stack = []
      seen_is_truthy = false

      while @pc < @instructions.length
        inst = @instructions[@pc]

        case inst[0]
        when IL::CONST_INT
          stack << inst[1].inspect
          @pc += 1
        when IL::CONST_FLOAT
          # Handle special Float values (NaN, Infinity)
          val = inst[1]
          if val.nan?
            stack << "Float::NAN"
          elsif val.infinite? == 1
            stack << "Float::INFINITY"
          elsif val.infinite? == -1
            stack << "-Float::INFINITY"
          else
            stack << val.inspect
          end
          @pc += 1
        when IL::CONST_STRING
          stack << inst[1].inspect
          @pc += 1
        when IL::CONST_TRUE
          stack << "true"
          @pc += 1
        when IL::CONST_FALSE
          stack << "false"
          @pc += 1
        when IL::CONST_NIL
          stack << "nil"
          @pc += 1
        when IL::CONST_EMPTY
          stack << "LiquidIL::EmptyLiteral.instance"
          @pc += 1
        when IL::CONST_BLANK
          stack << "LiquidIL::BlankLiteral.instance"
          @pc += 1
        when IL::CONST_RANGE
          stack << "LiquidIL::RangeValue.new(#{inst[1]}, #{inst[2]})"
          @pc += 1
        when IL::NEW_RANGE
          right = stack.pop || "0"
          left = stack.pop || "0"
          stack << "LiquidIL::RangeValue.new(#{left}, #{right})"
          @pc += 1
        when IL::FIND_VAR
          if (alias_var = @loop_var_aliases[inst[1]])
            stack << alias_var
          else
            stack << "_S.lookup(#{inst[1].inspect})"
          end
          @pc += 1
        when IL::FIND_SELF
          stack << "_S.self_drop"
          @pc += 1
        when IL::FIND_VAR_PATH
          stack << generate_var_path_expr(inst[1], inst[2])
          @pc += 1
        when IL::FIND_VAR_DYNAMIC
          name_ruby = stack.pop || "nil"
          stack << "_S.lookup(#{name_ruby})"
          @pc += 1
        when IL::LOOKUP_KEY
          key_ruby = stack.pop || "nil"
          obj_ruby = stack.pop || "nil"
          # Bracket access uses stricter semantics than property access
          stack << "_H.bl(#{obj_ruby}, #{key_ruby})"
          @pc += 1
        when IL::LOOKUP_CONST_KEY
          obj_ruby = stack.pop || "nil"
          stack << inline_lookup(obj_ruby, inst[1])
          @pc += 1
        when IL::LOOKUP_CONST_PATH
          obj_ruby = stack.pop || "nil"
          current = obj_ruby
          inst[1].each { |key| current = inline_lookup(current, key) }
          stack << current
          @pc += 1
        when IL::LOOKUP_COMMAND
          obj_ruby = stack.pop || "nil"
          cmd = inst[1]
          case cmd
          when "size", "length"
            stack << "((__o__ = #{obj_ruby}).respond_to?(:length) ? __o__.length : nil)"
          when "first"
            stack << "((__o__ = #{obj_ruby}).respond_to?(:first) ? __o__.first : nil)"
          when "last"
            stack << "((__o__ = #{obj_ruby}).respond_to?(:last) ? __o__.last : nil)"
          else
            stack << "_H.lookup(#{obj_ruby}, #{cmd.inspect})"
          end
          @pc += 1
        when IL::COMPARE
          right_ruby = stack.pop || "nil"
          left_ruby = stack.pop || "nil"
          op = inst[1]
          # Inline numeric comparisons: skip _H.cmp for numeric literals
          if NUMERIC_COMPARE_OPS.key?(op) && right_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
            ruby_op = COMPARE_OPS[op]
            # For safe expressions (size/length lookups, numeric literals, round/ceil/floor),
            # use || 0 pattern instead of is_a?(Numeric) check. Saves ~5ns per comparison.
            if left_ruby.include?("&.size") || left_ruby.include?("&.length") ||
               left_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/) ||
               left_ruby.include?(").round(") || left_ruby.include?(").ceil") || left_ruby.include?(").floor")
              stack << "(#{left_ruby} || 0) #{ruby_op} #{right_ruby}"
            else
              # Unwrap drops via to_liquid_value before numeric comparison
              stack << "((_t = #{left_ruby}); _t = _t.to_liquid_value; _t.is_a?(Numeric) && _t #{ruby_op} #{right_ruby})"
            end
          else
            stack << "_H.cmp(#{left_ruby}, #{right_ruby}, #{op.inspect}, _O, #{@current_file_lit.inspect})"
          end
          @pc += 1
        when IL::CONTAINS
          right_ruby = stack.pop || "nil"
          left_ruby = stack.pop || "nil"
          stack << "_H.ct(#{left_ruby}, #{right_ruby})"
          @pc += 1
        when IL::BOOL_NOT
          operand_ruby = stack.pop || "false"
          stack << "((_t = #{operand_ruby}); _t.nil? || _t == false)"
          @pc += 1
        when IL::IS_TRUTHY
          seen_is_truthy = true
          @pc += 1
        when IL::STORE_TEMP
          if stack.length > 1
            slot = inst[1]
            @pc += 1
            @temp_assignments ||= []
            @temp_assignments << [slot, stack.pop]
          else
            # Single item - this is the terminator case
            # DON'T increment @pc here - generate_expression_statement will read slot from inst
            return [stack.last, :store_temp]
          end
        when IL::LOAD_TEMP
          stack << "__temp_#{inst[1]}__"
          @pc += 1
        when IL::POP
          stack.pop
          @pc += 1
        when IL::DUP
          stack << stack.last if stack.any?
          @pc += 1
        when IL::CASE_COMPARE
          right_ruby = stack.pop || "nil"
          left_ruby = stack.pop || "nil"
          stack << "_U.ce?(#{right_ruby}, #{left_ruby})"
          @pc += 1
        when IL::BUILD_HASH
          count = inst[1]
          pairs = stack.pop(count * 2)
          stack << "{" + pairs.each_slice(2).map { |k, v| "#{k} => #{v}" }.join(", ") + "}"
          @pc += 1
        when IL::CALL_FILTER
          filter_pc = @pc
          argc = inst[2] || 0
          args = argc > 0 ? stack.pop(argc) : []
          input_ruby = stack.pop || "nil"
          stack << emit_filter_call(inst[1], input_ruby, args, filter_pc)
          @pc += 1
        when IL::JUMP
          # Follow unconditional jumps (optimizer may insert these for constant folding)
          @pc = inst[1]
        when IL::WRITE_VALUE
          @pc += 1
          return [stack.last, :write_value]
        when IL::ASSIGN
          @pc += 1
          return [stack.last, :assign]
        when IL::ASSIGN_LOCAL
          @pc += 1
          return [stack.last, :assign_local]
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE
          # Check if this is a short-circuit and/or pattern, not an actual if condition
          # Pattern: JUMP_IF_FALSE -> CONST_FALSE -> end (this is the false branch of 'and')
          # Pattern: JUMP_IF_TRUE -> CONST_TRUE -> end (this is the true branch of 'or')
          #
          # If we've already seen IS_TRUTHY, this JUMP_IF_* is the actual condition branch
          if seen_is_truthy
            return [stack.last, :condition]
          end

          jump_target = inst[1]
          # Skip LABEL instructions to find the actual target
          actual_target = jump_target
          while @instructions[actual_target]&.[](0) == IL::LABEL
            actual_target += 1
          end
          target_inst = @instructions[actual_target]

          # For short-circuit detection, check if CONST_TRUE/FALSE is followed by expression continuation
          # vs STORE_TEMP (which indicates case/when pattern where it sets a "matched" flag)
          next_after_target = @instructions[actual_target + 1]
          is_short_circuit_pattern = next_after_target &&
            next_after_target[0] != IL::STORE_TEMP &&
            next_after_target[0] != IL::WRITE_RAW &&
            next_after_target[0] != IL::WRITE_VALUE
          if inst[0] == IL::JUMP_IF_FALSE && target_inst&.[](0) == IL::CONST_FALSE && is_short_circuit_pattern
            left_ruby = stack.pop || "false"
            @pc += 1
            right_start = @pc
            while @pc < jump_target
              build_inst = @instructions[@pc]
              break if build_inst.nil?
              case build_inst[0]
              when IL::JUMP
                @pc = build_inst[1]
                break
              when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE,
                   IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK, IL::CONST_RANGE, IL::NEW_RANGE,
                   IL::FIND_VAR, IL::FIND_VAR_PATH, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY, IL::LOOKUP_CONST_PATH,
                   IL::LOOKUP_COMMAND, IL::COMPARE, IL::CONTAINS, IL::BOOL_NOT, IL::IS_TRUTHY, IL::CALL_FILTER,
                   IL::LOAD_TEMP
                case build_inst[0]
                when IL::CONST_INT then stack << build_inst[1].inspect; @pc += 1
                when IL::CONST_FLOAT then stack << build_inst[1].inspect; @pc += 1
                when IL::CONST_STRING then stack << build_inst[1].inspect; @pc += 1
                when IL::CONST_TRUE then stack << "true"; @pc += 1
                when IL::CONST_FALSE then stack << "false"; @pc += 1
                when IL::CONST_NIL then stack << "nil"; @pc += 1
                when IL::CONST_EMPTY then stack << "LiquidIL::EmptyLiteral.instance"; @pc += 1
                when IL::CONST_BLANK then stack << "LiquidIL::BlankLiteral.instance"; @pc += 1
                when IL::FIND_VAR then stack << "_S.lookup(#{build_inst[1].inspect})"; @pc += 1
                when IL::FIND_VAR_PATH then stack << generate_var_path_expr(build_inst[1], build_inst[2]); @pc += 1
                when IL::FIND_SELF then stack << "_S.self_drop"; @pc += 1
                when IL::LOAD_TEMP then stack << "__temp_#{build_inst[1]}__"; @pc += 1
                when IL::LOOKUP_CONST_KEY
                  obj_ruby = stack.pop || "nil"
                  stack << inline_lookup(obj_ruby, build_inst[1])
                  @pc += 1
                when IL::COMPARE
                  right_ruby = stack.pop || "nil"
                  left_ruby_inner = stack.pop || "nil"
                  cmp_op = build_inst[1]
                  # Inline numeric comparisons: skip _H.cmp for numeric literals
                  if NUMERIC_COMPARE_OPS.key?(cmp_op) && right_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
                    ruby_op = COMPARE_OPS[cmp_op]
                    if left_ruby_inner.include?("&.size") || left_ruby_inner.include?("&.length") ||
                       left_ruby_inner.match?(/\A-?[0-9]+\.?[0-9]*\z/)
                      stack << "(#{left_ruby_inner} || 0) #{ruby_op} #{right_ruby}"
                    else
                      stack << "((_t = #{left_ruby_inner}); _t = _t.to_liquid_value; _t.is_a?(Numeric) && _t #{ruby_op} #{right_ruby})"
                    end
                  else
                    stack << "_H.cmp(#{left_ruby_inner}, #{right_ruby}, #{cmp_op.inspect}, _O, #{@current_file_lit.inspect})"
                  end
                  @pc += 1
                when IL::CONTAINS
                  right_ruby = stack.pop || "nil"
                  left_ruby_inner = stack.pop || "nil"
                  stack << "_H.ct(#{left_ruby_inner}, #{right_ruby})"
                  @pc += 1
                when IL::BOOL_NOT
                  operand_ruby = stack.pop || "false"
                  stack << "((_t = #{operand_ruby}); _t.nil? || _t == false)"
                  @pc += 1
                when IL::IS_TRUTHY then @pc += 1
                else @pc += 1
                end
              else
                break
              end
            end
            right_ruby = stack.pop || "false"
            stack << "((#{inline_truthy(left_ruby)}) && (#{inline_truthy(right_ruby)}))"
            if @instructions[@pc]&.[](0) == IL::IS_TRUTHY
              @pc += 1
            end
          elsif inst[0] == IL::JUMP_IF_TRUE && target_inst&.[](0) == IL::CONST_TRUE && is_short_circuit_pattern
            or_operands = [stack.pop || "false"]
            @pc += 1

            while @pc < @instructions.length
              build_inst = @instructions[@pc]
              break if build_inst.nil?

              case build_inst[0]
              when IL::IS_TRUTHY
                @pc += 1
                break
              when IL::CONST_TRUE
                @pc += 1
              when IL::JUMP
                jmp_target = build_inst[1]
                if @instructions[jmp_target]&.[](0) == IL::CONST_TRUE || @instructions[jmp_target]&.[](0) == IL::IS_TRUTHY
                  @pc = jmp_target
                else
                  @pc += 1
                end
              when IL::LABEL
                @pc += 1
              when IL::FIND_VAR
                # Build Ruby string for this OR operand
                or_ruby = build_or_operand_ruby(build_inst[1])
                or_operands << or_ruby if or_ruby
                break unless or_ruby
              when IL::FIND_SELF
                or_operands << "_S.self_drop"
                @pc += 1
                break
              when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_FALSE, IL::CONST_NIL
                case build_inst[0]
                when IL::CONST_INT then or_operands << build_inst[1].inspect
                when IL::CONST_FLOAT then or_operands << build_inst[1].inspect
                when IL::CONST_STRING then or_operands << build_inst[1].inspect
                when IL::CONST_FALSE then or_operands << "false"
                when IL::CONST_NIL then or_operands << "nil"
                end
                @pc += 1
                if @instructions[@pc]&.[](0) == IL::JUMP
                  @pc = @instructions[@pc][1]
                end
                break
              else
                break
              end
            end

            stack << or_operands.map { |c| "(#{inline_truthy(c)})" }.join(" || ")
          else
            # Regular if condition
            return [stack.last, :condition]
          end
        else
          # Unknown or terminating instruction
          break
        end
      end

      [stack.last, :none]
    end

    # Generate variable path access (a.b.c)
    def generate_var_path_expr(var, path)
      if (alias_var = @loop_var_aliases[var])
        result = alias_var
      else
        result = "_S.lookup(#{var.inspect})"
      end
      path.each do |key|
        result = inline_lookup(result, key)
      end
      result
    end

    # Check if current position starts a for loop
    # For loops can start with:
    # - FIND_VAR collection -> JUMP_IF_EMPTY -> FOR_INIT
    # - Expression (CONST_*, NEW_RANGE) -> JUMP_IF_EMPTY -> FOR_INIT
    def peek_for_loop?
      # Scan forward looking for JUMP_IF_EMPTY followed by FOR_INIT
      # Note: optimizer may insert hoisted expressions between JUMP_IF_EMPTY and FOR_INIT
      i = @pc
      while i < @instructions.length
        inst = @instructions[i]
        break if inst.nil?

        case inst[0]
        when IL::JUMP_IF_EMPTY
          # After JUMP_IF_EMPTY, look for FOR_INIT (may have hoisted expressions
          # or offset/limit expressions in between — including dotted lookups)
          j = i + 1
          while j < @instructions.length
            next_inst = @instructions[j]
            break if next_inst.nil?
            case next_inst[0]
            when IL::FOR_INIT
              return true
            when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::CONST_INT, IL::CONST_FLOAT,
                 IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_NIL,
                 IL::CONST_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
                 IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::NEW_RANGE,
                 IL::STORE_TEMP, IL::LOAD_TEMP, IL::DUP
              j += 1
            else
              break
            end
          end
          return false
        when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
             IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK,
             IL::FIND_VAR, IL::FIND_VAR_PATH, IL::NEW_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
             IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::CALL_FILTER, IL::COMPARE, IL::CONTAINS,
             IL::BOOL_NOT, IL::IS_TRUTHY, IL::STORE_TEMP, IL::LOAD_TEMP, IL::CASE_COMPARE
          i += 1
        else
          return false
        end
      end
      false
    end

    # Check if current position starts a tablerow loop
    # Tablerow doesn't have JUMP_IF_EMPTY, just: collection -> [limit] -> [offset] -> TABLEROW_INIT
    def peek_tablerow?
      i = @pc
      while i < @instructions.length
        inst = @instructions[i]
        break if inst.nil?

        case inst[0]
        when IL::TABLEROW_INIT
          return true
        when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
             IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK,
             IL::FIND_VAR, IL::FIND_VAR_PATH, IL::NEW_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
             IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::CALL_FILTER,
             IL::STORE_TEMP, IL::LOAD_TEMP, IL::DUP
          i += 1
        else
          return false
        end
      end
      false
    end

    # Check if current position starts an if statement
    def peek_if_statement?
      pos = @pc
      iterations = 0
      while (next_inst = @instructions[pos])
        case next_inst[0]
        when IL::IS_TRUTHY
          following = @instructions[pos + 1]
          return following&.[](0) == IL::JUMP_IF_FALSE || following&.[](0) == IL::JUMP_IF_TRUE
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE
          return true
        when IL::FOR_INIT, IL::HALT, IL::WRITE_VALUE, IL::ASSIGN, IL::ASSIGN_LOCAL
          # These terminate the expression without being an if condition
          return false
        when IL::STORE_TEMP
          # STORE_TEMP after DUP is mid-expression caching (continue scanning)
          # Standalone STORE_TEMP terminates the expression
          prev = pos > 0 ? @instructions[pos - 1] : nil
          return false unless prev && prev[0] == IL::DUP
          pos += 1
        when IL::JUMP
          # Follow forward jumps to find IS_TRUTHY/JUMP_IF_FALSE (optimizer chains JUMPs)
          target = next_inst[1]
          if target > pos
            pos = target
          else
            pos += 1
          end
        else
          pos += 1
        end
        iterations += 1
        break if iterations > 50 # Safety limit for very long chains
      end
      false
    end

    # Generate a for loop
    def generate_for_loop(indent)
      prefix = INDENT[indent]

      # Build collection expression (handles FIND_VAR, ranges, filter chains, etc.)
      coll_expr, _ = build_expression

      # Should now be at JUMP_IF_EMPTY
      inst = @instructions[@pc]
      return nil unless inst && inst[0] == IL::JUMP_IF_EMPTY

      end_pc = inst[1]
      @pc += 1

      generate_for_loop_body_with_expr(coll_expr, end_pc, indent)
    end

    # Generate for loop body (legacy - called from generate_statement for FOR_INIT at current position)
    def generate_for_loop_body(collection_var, end_pc, indent)
      generate_for_loop_body_with_expr(ruby_var_reference(collection_var || "items"), end_pc, indent)
    end

    # Generate for loop body with expression
    def generate_for_loop_body_with_expr(coll_expr, end_pc, indent)
      prefix = INDENT[indent]
      pre_loop_code = String.new

      # First, look ahead to find FOR_INIT and determine offset/limit presence
      # This helps us avoid consuming offset/limit values as pre-loop expressions
      for_init_idx = @pc
      while for_init_idx < @instructions.length && @instructions[for_init_idx][0] != IL::FOR_INIT
        for_init_idx += 1
      end

      has_limit = false
      has_offset = false
      if for_init_idx < @instructions.length
        fi = @instructions[for_init_idx]
        has_limit = fi[3]
        has_offset = fi[4]
      end

      # Count how many values need to be on stack for offset/limit
      values_needed = (has_offset ? 1 : 0) + (has_limit ? 1 : 0)

      # Skip any pre-loop hoisted expressions (FIND_VAR + STORE_TEMP patterns).
      # Everything else before FOR_INIT is offset/limit values — leave for
      # build_single_value_expression to consume.
      while @pc < @instructions.length && @instructions[@pc][0] != IL::FOR_INIT
        inst = @instructions[@pc]
        case inst[0]
        when IL::FIND_VAR
          next_inst = @instructions[@pc + 1]
          if next_inst && next_inst[0] == IL::STORE_TEMP
            var_name = inst[1]
            slot = next_inst[1]
            @pc += 2
            pre_loop_code << "#{prefix}__temp_#{slot}__ = _S.lookup(#{var_name.inspect})\n"
          else
            break  # offset/limit expression starts here
          end
        when IL::STORE_TEMP
          @pc += 1
        else
          break  # offset/limit expression starts here
        end
      end

      # Handle offset/limit expressions if present (pushed onto stack before FOR_INIT)
      # IL emits: offset, limit (in that order) so we read offset first, then limit
      limit_expr = nil
      offset_expr = nil

      if for_init_idx < @instructions.length
        # Build offset expression if present (emitted first in IL)
        if has_offset && @pc < for_init_idx
          offset_expr = build_single_value_expression
        end

        # Build limit expression if present (emitted second in IL)
        if has_limit && @pc < for_init_idx
          limit_expr = build_single_value_expression
        end
      end

      # Consume: FOR_INIT
      for_init = @instructions[@pc]
      return nil unless for_init && for_init[0] == IL::FOR_INIT

      item_var = for_init[1]
      loop_name = for_init[2]
      has_limit = for_init[3]
      has_offset = for_init[4]
      offset_continue = for_init[5]
      reversed = for_init[6]
      @pc += 1

      # Track loop depth for nested loops - increment BEFORE parsing body.
      # Naming uses @loop_name_base so a partial body INLINED into another
      # template's loop can't collide with the call site's loop locals
      # (each partial compilation gets a unique base; see compile_partial).
      depth = @loop_name_base + @loop_depth
      @loop_depth += 1

      # Skip structural instructions
      while @pc < @instructions.length
        case @instructions[@pc][0]
        when IL::PUSH_SCOPE, IL::PUSH_FORLOOP, IL::FOR_NEXT
          @pc += 1
        when IL::ASSIGN_LOCAL
          if @instructions[@pc][1] == item_var
            @pc += 1
          else
            break
          end
        else
          break
        end
      end

      # Parse loop body — set up aliases so expression lowering can resolve
      # loop vars to Ruby locals instead of _S.lookup() calls.
      saved_aliases = {}
      alias_names = { item_var => "_i#{depth}__", "forloop" => "_fl#{depth}__" }
      alias_names.each do |liq_var, ruby_var|
        saved_aliases[liq_var] = @loop_var_aliases[liq_var]
        @loop_var_aliases[liq_var] = ruby_var
      end

      body_start = @pc
      body_code = String.new

      while @pc < @instructions.length
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::JUMP
          # Check if jumping back (end of loop)
          if inst[1] <= body_start || @instructions[@pc + 1]&.[](0) == IL::POP_INTERRUPT
            @pc += 1
            break
          else
            result = generate_statement(indent + 3)
            break if result.nil?
            body_code << result
          end
        when IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END
          # These mark end of loop body - don't consume, let cleanup handle them
          # Note: JUMP_IF_INTERRUPT is NOT included because it appears mid-body after break/continue
          break
        when IL::HALT
          break
        else
          result = generate_statement(indent + 3)
          break if result.nil?
          body_code << result
        end
      end

      # Restore previous aliases (handles nested loops correctly)
      saved_aliases.each do |liq_var, prev|
        if prev
          @loop_var_aliases[liq_var] = prev
        else
          @loop_var_aliases.delete(liq_var)
        end
      end

      # Consume cleanup and detect for-else pattern
      else_end_target = nil
      while @pc < @instructions.length
        inst = @instructions[@pc]
        case inst&.[](0)
        when IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END, IL::LABEL
          @pc += 1
        when IL::JUMP
          # If this JUMP targets past end_pc, there's an else block
          if end_pc && inst[1] > end_pc
            else_end_target = inst[1]
          end
          @pc += 1
        else
          break
        end
      end

      # Parse else block if present (between end_pc and else_end_target)
      else_code = String.new
      if else_end_target && end_pc && @pc == end_pc
        while @pc < else_end_target
          inst = @instructions[@pc]
          break if inst.nil? || inst[0] == IL::HALT
          result = generate_statement(indent + 1)
          break if result.nil?
          else_code << result
        end
      end

      # Generate the loop code with unique variable names for nested loops
      code = String.new
      code << pre_loop_code unless pre_loop_code.empty?
      coll_ruby = coll_expr || "nil"

      # Use depth-indexed variables for forloop and collection
      forloop_var = "_fl#{depth}__"
      coll_var = "_c#{depth}__"
      item_var_internal = "_i#{depth}__"
      idx_var = "_x#{depth}__"

      # Get parent forloop reference (if nested)
      # Always check scope for existing forloop - this handles:
      # - parentloop access in includes (depth 0 with outer loop in scope)
      # - for loops inside tablerows (depth > 0 but no _fl{depth-1}__ exists)
      parent_forloop = "_S.lookup('forloop')"

      # Check what the loop body actually needs
      needs_scope_sync = body_code.include?(".call(") ||
                         body_code.include?("execute_dynamic_partial") ||
                         body_code.include?("ForloopDrop.new") ||
                         body_code.include?("_S.lookup('forloop')") ||
                         body_code.include?("_S.lookup(#{item_var.inspect})")
      needs_forloop = body_code.include?(forloop_var) || needs_scope_sync
      needs_catch = body_code.include?(":loop_break_#{depth}") || body_code.include?("throw(:loop_break")
      needs_error_handling = has_offset || has_limit
      needs_slicing = limit_expr || offset_expr || offset_continue

      # Fast path: simple loops use direct while loop — no block yield overhead
      if !needs_forloop && !needs_scope_sync && !needs_catch && !needs_error_handling &&
         !reversed && !needs_slicing && !offset_continue && else_code.empty?
        coll_var_name = "__coll#{depth}__"
        idx_var_name = "__i#{depth}__"
        len_var_name = "__len#{depth}__"
        code << "#{prefix}#{coll_var_name} = #{coll_ruby}\n"
        # For simple hash lookups, ||= [] is faster than _H.ti() since Arrays/nils dominate
        if coll_ruby.match?(/\A_[a-z]\d+__\["[^"]+"\]\z/) || coll_ruby.match?(/\A_cache_\w+__\z/)
          code << "#{prefix}#{coll_var_name} ||= []\n"
        else
          code << "#{prefix}#{coll_var_name} = _H.ti(#{coll_var_name}) unless #{coll_var_name}.is_a?(Array)\n"
        end
        code << "#{prefix}#{len_var_name} = #{coll_var_name}.length\n"
        code << "#{prefix}#{idx_var_name} = 0\n"
        code << "#{prefix}while #{idx_var_name} < #{len_var_name}\n"
        code << "#{prefix}  #{item_var_internal} = #{coll_var_name}[#{idx_var_name}]\n"
        # Increment BEFORE the body: {% continue %} compiles to `next`, which
        # would skip a trailing increment and loop forever.
        code << "#{prefix}  #{idx_var_name} += 1\n"
        if @has_resource_limits
          code << "#{prefix}  _S.increment_render_score!\n"
          code << "#{prefix}  _S.check_output_limit!(_O)\n"
        end
        # body_code is at INDENT[indent+3], needs INDENT[indent+1] (strip 4 spaces)
        code << body_code.gsub(/^#{Regexp.escape(prefix)}      /, prefix + "  ")
        code << "#{prefix}end\n"
        @loop_depth -= 1
        return code
      end

      # Complex path: full collection prep with offset/limit/slicing support
      code << "#{prefix}begin\n" if needs_error_handling
      inner_prefix = needs_error_handling ? "#{prefix}  " : prefix

      if needs_slicing || has_offset || has_limit
        code << "#{inner_prefix}_oc#{depth}__ = #{coll_ruby}\n"
        code << "#{inner_prefix}_is#{depth}__ = _oc#{depth}__.is_a?(String)\n"
        code << "#{inner_prefix}_in#{depth}__ = _oc#{depth}__.nil? || _oc#{depth}__ == false\n"
        code << "#{inner_prefix}#{coll_var} = _oc#{depth}__.is_a?(Array) ? _oc#{depth}__ : _H.ti(_oc#{depth}__)\n"
      else
        code << "#{inner_prefix}#{coll_var} = #{coll_ruby}\n"
        code << "#{inner_prefix}#{coll_var} = _H.ti(#{coll_var}) unless #{coll_var}.is_a?(Array)\n"
      end

      offset_var = "_so#{depth}__"
      if offset_continue
        code << "#{inner_prefix}#{offset_var} = _S.for_offset(#{loop_name.inspect})\n"
      elsif offset_expr
        offset_ruby = offset_expr
        if has_offset
          code << "#{inner_prefix}_ov#{depth}__ = #{offset_ruby}\n"
          code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _in#{depth}__ || _H.vi(_ov#{depth}__)\n"
          code << "#{inner_prefix}#{offset_var} = _ov#{depth}__.to_i\n"
        else
          code << "#{inner_prefix}#{offset_var} = (#{offset_ruby}).to_i\n"
        end
      else
        code << "#{inner_prefix}#{offset_var} = 0\n"
      end

      needs_slicing = limit_expr || offset_expr || offset_continue
      if limit_expr
        limit_ruby = limit_expr
        if has_limit
          code << "#{inner_prefix}_lv#{depth}__ = #{limit_ruby}\n"
          code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _in#{depth}__ || _H.vi(_lv#{depth}__)\n"
          code << "#{inner_prefix}_to#{depth}__ = #{offset_var} + _lv#{depth}__.to_i\n"
        else
          code << "#{inner_prefix}_to#{depth}__ = #{offset_var} + (#{limit_ruby}).to_i\n"
        end
        code << "#{inner_prefix}#{coll_var} = _H.sc(#{coll_var}, #{offset_var}, _to#{depth}__) unless _is#{depth}__\n"
      elsif needs_slicing
        code << "#{inner_prefix}#{coll_var} = _H.sc(#{coll_var}, #{offset_var}, nil) unless _is#{depth}__\n"
      end

      code << "#{inner_prefix}#{coll_var} = #{coll_var}.reverse\n" if reversed

      code << "#{inner_prefix}if !#{coll_var}.empty?\n"
      if needs_forloop
        code << "#{inner_prefix}  #{forloop_var} = LiquidIL::ForloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{parent_forloop})\n"
      end
      # Save previous values for scope cleanup after loop
      if needs_scope_sync
        code << "#{inner_prefix}  _pfl#{depth}__ = _S.lookup('forloop')\n"
      end
      code << "#{inner_prefix}  _pi#{depth}__ = _S.lookup(#{item_var.inspect})\n" if needs_scope_sync
      code << "#{inner_prefix}  catch(:loop_break_#{depth}) do\n" if needs_catch
      if needs_forloop
        # Use while loop instead of each_with_index block — avoids block yield overhead
        code << "#{inner_prefix}    #{idx_var} = 0\n"
        code << "#{inner_prefix}    #{coll_var}_len = #{coll_var}.length\n"
        code << "#{inner_prefix}    while #{idx_var} < #{coll_var}_len\n"
        code << "#{inner_prefix}      #{item_var_internal} = #{coll_var}[#{idx_var}]\n"
        code << "#{inner_prefix}      #{forloop_var}.index0 = #{idx_var}\n"
        # Increment BEFORE the body: `next` (continue / interrupt checks) would
        # skip a trailing increment and loop forever.
        code << "#{inner_prefix}      #{idx_var} += 1\n"
      else
        # No forloop needed — use plain each (skip index tracking overhead)
        code << "#{inner_prefix}    #{coll_var}.each do |#{item_var_internal}|\n"
      end
      if needs_scope_sync
        code << "#{inner_prefix}      _S.assign_local('forloop', #{forloop_var})\n"
        code << "#{inner_prefix}      _S.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
      end
      # Resource limit checks — only emitted when limits are configured
      if @has_resource_limits
        code << "#{inner_prefix}      _S.increment_render_score!\n"
        code << "#{inner_prefix}      _S.check_output_limit!(_O)\n"
      end
      # Adjust body_code indentation if we have error handling
      if needs_error_handling
        body_code = body_code.gsub(/^/, "  ")
      end
      code << body_code
      code << "#{inner_prefix}    end\n"
      code << "#{inner_prefix}  end\n" if needs_catch
      if needs_forloop
        code << "#{inner_prefix}  #{forloop_var}.index0 = #{coll_var}.length\n"
      end
      code << "#{inner_prefix}  _S.set_for_offset(#{loop_name.inspect}, #{offset_var} + #{coll_var}.length)\n"
      if needs_scope_sync
        code << "#{inner_prefix}  _S.assign_local('forloop', _pfl#{depth}__)\n"
        code << "#{inner_prefix}  _S.assign_local(#{item_var.inspect}, _pi#{depth}__)\n"
      end

      # Add else block if present (for-else pattern)
      if !else_code.empty?
        code << "#{inner_prefix}else\n"
        # Adjust else_code indentation if we have error handling
        if needs_error_handling
          else_code = else_code.gsub(/^/, "  ")
        end
        code << else_code
      end

      code << "#{inner_prefix}end\n"

      # Close error handling block
      if needs_error_handling
        code << "#{prefix}rescue LiquidIL::RuntimeError => _e#{depth}__\n"
        code << "#{prefix}  raise unless _S.render_errors\n"
        code << "#{prefix}  _loc#{depth}__ = _e#{depth}__.file ? \"\#{_e#{depth}__.file} line \#{_e#{depth}__.line}\" : \"line \#{_e#{depth}__.line}\"\n"
        code << "#{prefix}  _O << \"Liquid error (\#{_loc#{depth}__}): \#{_e#{depth}__.message}\"\n"
        code << "#{prefix}end\n"
      end

      @loop_depth -= 1
      code
    end

    # Generate a tablerow loop (called when FIND_VAR starts a tablerow sequence)
    def generate_tablerow(indent)
      prefix = INDENT[indent]

      # Scan forward to find TABLEROW_INIT and determine what params it has
      tablerow_init_idx = @pc
      while tablerow_init_idx < @instructions.length && @instructions[tablerow_init_idx][0] != IL::TABLEROW_INIT
        tablerow_init_idx += 1
      end

      return nil if tablerow_init_idx >= @instructions.length

      tablerow_init = @instructions[tablerow_init_idx]
      item_var = tablerow_init[1]
      loop_name = tablerow_init[2]
      has_limit = tablerow_init[3]
      has_offset = tablerow_init[4]
      cols = tablerow_init[5]  # nil, :dynamic, :explicit_nil, or integer

      # IL stack order: collection, limit (if has_limit), offset (if has_offset), cols (if :dynamic)
      # We need to read them in that order
      # Use build_single_value_expression to read ONE value at a time

      # Read collection expression
      coll_expr = build_single_value_expression

      # Read limit expression if present
      limit_expr = nil
      if has_limit && @pc < tablerow_init_idx
        limit_expr = build_single_value_expression
      end

      # Read offset expression if present
      offset_expr = nil
      if has_offset && @pc < tablerow_init_idx
        offset_expr = build_single_value_expression
      end

      # Read cols expression if dynamic
      cols_expr = nil
      if cols == :dynamic && @pc < tablerow_init_idx
        cols_expr = build_single_value_expression
      end

      # Handle any hoisted FIND_VAR + STORE_TEMP patterns before TABLEROW_INIT
      pre_loop_code = String.new
      while @pc < tablerow_init_idx
        inst = @instructions[@pc]
        case inst[0]
        when IL::FIND_VAR
          next_inst = @instructions[@pc + 1]
          if next_inst && next_inst[0] == IL::STORE_TEMP
            var_name = inst[1]
            slot = next_inst[1]
            @pc += 2
            pre_loop_code << "#{"  " * indent}__temp_#{slot}__ = _S.lookup(#{var_name.inspect})\n"
          else
            break
          end
        when IL::STORE_TEMP
          @pc += 1
        else
          break
        end
      end

      # Move to TABLEROW_INIT and consume it
      @pc = tablerow_init_idx + 1

      code = pre_loop_code
      code << generate_tablerow_body(coll_expr, limit_expr, offset_expr, cols_expr, cols, has_limit, has_offset, item_var, loop_name, indent).to_s
      code
    end

    # Generate tablerow body (called when expressions already built or at TABLEROW_INIT)
    def generate_tablerow_body(coll_expr, limit_expr, offset_expr, cols_expr, cols, has_limit, has_offset, item_var, loop_name, indent)
      prefix = INDENT[indent]

      # If called directly from TABLEROW_INIT, get params from instruction
      if coll_expr.nil?
        tablerow_init = @instructions[@pc]
        return nil unless tablerow_init && tablerow_init[0] == IL::TABLEROW_INIT

        item_var = tablerow_init[1]
        loop_name = tablerow_init[2]
        has_limit = tablerow_init[3]
        has_offset = tablerow_init[4]
        cols = tablerow_init[5]
        @pc += 1
        coll_expr = ruby_var_reference("items")
      end

      # Track loop depth for nested loops (naming offset by @loop_name_base —
      # see generate_for_loop)
      depth = @loop_name_base + @loop_depth
      @loop_depth += 1

      # Skip structural instructions (PUSH_SCOPE, TABLEROW_NEXT)
      while @pc < @instructions.length
        case @instructions[@pc][0]
        when IL::PUSH_SCOPE, IL::TABLEROW_NEXT, IL::LABEL
          @pc += 1
        when IL::ASSIGN_LOCAL
          if @instructions[@pc][1] == item_var
            @pc += 1
          else
            break
          end
        else
          break
        end
      end

      # Parse loop body
      body_start = @pc
      body_code = String.new

      while @pc < @instructions.length
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::JUMP
          # Check if jumping back (end of loop)
          if inst[1] <= body_start || @instructions[@pc + 1]&.[](0) == IL::POP_INTERRUPT
            @pc += 1
            break
          else
            result = generate_statement(indent + 3)
            break if result.nil?
            body_code << result
          end
        when IL::POP_INTERRUPT, IL::POP_SCOPE, IL::TABLEROW_END
          # These mark end of loop body
          break
        when IL::HALT
          break
        else
          result = generate_statement(indent + 3)
          break if result.nil?
          body_code << result
        end
      end

      # Consume cleanup instructions (including loop-back JUMPs)
      while @pc < @instructions.length
        inst = @instructions[@pc]
        case inst&.[](0)
        when IL::POP_INTERRUPT, IL::POP_SCOPE, IL::TABLEROW_END, IL::LABEL, IL::JUMP_IF_INTERRUPT
          @pc += 1
        when IL::JUMP
          # Backward jumps are loop-back instructions, consume them
          if inst[1] < @pc
            @pc += 1
          else
            break
          end
        else
          break
        end
      end

      # Generate the tablerow code
      code = String.new
      coll_var = "__tablerow_coll_#{depth}__"
      tablerowloop_var = "__tablerowloop_#{depth}__"
      item_var_internal = "__tablerow_item_#{depth}__"
      idx_var = "__tablerow_idx_#{depth}__"
      cols_var = "__tablerow_cols_#{depth}__"
      coll_ruby = coll_expr || "nil"

      code << "#{prefix}__orig_tablerow_coll_#{depth}__ = #{coll_ruby}\n"
      code << "#{prefix}_is#{depth}__ = __orig_tablerow_coll_#{depth}__.is_a?(String)\n"
      code << "#{prefix}_in#{depth}__ = __orig_tablerow_coll_#{depth}__.nil? || __orig_tablerow_coll_#{depth}__ == false\n"
      code << "#{prefix}#{coll_var} = _H.ti(__orig_tablerow_coll_#{depth}__)\n"

      # Handle cols parameter
      case cols
      when :dynamic
        if cols_expr
          code << "#{prefix}__cols_val_#{depth}__ = #{cols_expr}\n"
          code << "#{prefix}if __cols_val_#{depth}__.nil?\n"
          code << "#{prefix}  #{cols_var} = #{coll_var}.length\n"
          code << "#{prefix}  __cols_explicit_nil_#{depth}__ = true\n"
          code << "#{prefix}elsif !_in#{depth}__ && !_H.vi(__cols_val_#{depth}__)\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1)\n"
          code << "#{prefix}else\n"
          code << "#{prefix}  #{cols_var} = __cols_val_#{depth}__.to_i\n"
          code << "#{prefix}  __cols_explicit_nil_#{depth}__ = false\n"
          code << "#{prefix}end\n"
        else
          code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
          code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
        end
      when :explicit_nil
        code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
        code << "#{prefix}__cols_explicit_nil_#{depth}__ = true\n"
      when nil
        code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
        code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
      else
        code << "#{prefix}#{cols_var} = #{cols}\n"
        code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
      end

      # Handle offset if present (validate and apply) - for strings, offset is ignored
      # Note: offset must be applied BEFORE limit (VM order)
      # Skip all processing if collection is nil/false (no output will be generated anyway)
      if has_offset
        if offset_expr
          offset_ruby = offset_expr
          code << "#{prefix}_ov#{depth}__ = #{offset_ruby}\n"
          code << "#{prefix}unless _in#{depth}__\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _H.vi(_ov#{depth}__)\n"
          code << "#{prefix}  __offset_#{depth}__ = _ov#{depth}__.nil? ? 0 : _ov#{depth}__.to_i\n"
          code << "#{prefix}  __offset_#{depth}__ = [__offset_#{depth}__, 0].max\n"
          code << "#{prefix}  #{coll_var} = #{coll_var}.drop(__offset_#{depth}__) unless _is#{depth}__\n"
          code << "#{prefix}end\n"
        end
      end

      # Handle limit if present (validate and apply) - for strings, limit is ignored
      # nil limit means take 0 items for tablerow (different from for loop)
      # Skip all processing if collection is nil/false (no output will be generated anyway)
      if has_limit
        if limit_expr
          limit_ruby = limit_expr
          code << "#{prefix}_lv#{depth}__ = #{limit_ruby}\n"
          code << "#{prefix}unless _in#{depth}__\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _H.vi(_lv#{depth}__)\n"
          code << "#{prefix}  __limit_#{depth}__ = _lv#{depth}__.nil? ? 0 : _lv#{depth}__.to_i\n"
          code << "#{prefix}  __limit_#{depth}__ = 0 if __limit_#{depth}__ < 0\n"
          code << "#{prefix}  #{coll_var} = #{coll_var}.take(__limit_#{depth}__) unless _is#{depth}__\n"
          code << "#{prefix}end\n"
        end
      end

      # Ensure cols is at least 1 to avoid division by zero
      code << "#{prefix}#{cols_var} = [#{cols_var}, 1].max\n"

      code << "#{prefix}_S.push_scope\n"
      code << "#{prefix}#{tablerowloop_var} = LiquidIL::TablerowloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{cols_var}, nil, __cols_explicit_nil_#{depth}__)\n"

      # Wrap with catch for break support
      code << "#{prefix}catch(:loop_break_#{depth}) do\n"

      # Output opening row tag for empty collections
      code << "#{prefix}  if #{coll_var}.empty? && !_in#{depth}__\n"
      code << "#{prefix}    _O << \"<tr class=\\\"row1\\\">\\n\"\n"
      code << "#{prefix}    _O << \"</tr>\\n\"\n"
      code << "#{prefix}  end\n"

      code << "#{prefix}  #{coll_var}.each_with_index do |#{item_var_internal}, #{idx_var}|\n"
      code << "#{prefix}    #{tablerowloop_var}.index0 = #{idx_var}\n"
      code << "#{prefix}    _S.assign_local('tablerowloop', #{tablerowloop_var})\n"
      code << "#{prefix}    _S.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
      if @has_resource_limits
        code << "#{prefix}    _S.increment_render_score!\n"
        code << "#{prefix}    _S.check_output_limit!(_O)\n"
      end

      # Output HTML tags before body content
      code << "#{prefix}    if #{idx_var} > 0\n"
      code << "#{prefix}      _O << \"</td>\"\n"
      code << "#{prefix}      if (#{idx_var} % #{cols_var}) == 0\n"
      code << "#{prefix}        _O << \"</tr>\\n\"\n"
      code << "#{prefix}      end\n"
      code << "#{prefix}    end\n"

      code << "#{prefix}    if (#{idx_var} % #{cols_var}) == 0\n"
      code << "#{prefix}      __row__ = (#{idx_var} / #{cols_var}) + 1\n"
      code << "#{prefix}      if __row__ == 1\n"
      code << "#{prefix}        _O << \"<tr class=\\\"row\#{__row__}\\\">\\n\"\n"
      code << "#{prefix}      else\n"
      code << "#{prefix}        _O << \"<tr class=\\\"row\#{__row__}\\\">\"\n"
      code << "#{prefix}      end\n"
      code << "#{prefix}    end\n"
      code << "#{prefix}    __col__ = (#{idx_var} % #{cols_var}) + 1\n"
      code << "#{prefix}    _O << \"<td class=\\\"col\#{__col__}\\\">\"\n"

      # Body content
      code << body_code

      code << "#{prefix}  end\n"  # end each_with_index
      code << "#{prefix}end\n"    # end catch

      # Close final tags
      code << "#{prefix}if !#{coll_var}.empty?\n"
      code << "#{prefix}  _O << \"</td>\"\n"
      code << "#{prefix}  _O << \"</tr>\\n\"\n"
      code << "#{prefix}end\n"
      code << "#{prefix}_S.pop_scope\n"

      @loop_depth -= 1
      code
    end

    # Generate an if statement
    def generate_if_statement(indent)
      prefix = INDENT[indent]

      # Build condition expression
      @temp_assignments = nil
      cond_expr, _ = build_expression

      # Emit any temp assignments generated during condition expression building
      # (e.g., DUP + STORE_TEMP caching a variable for reuse in both condition and body)
      temp_code = String.new
      if @temp_assignments
        @temp_assignments.each do |slot, temp_ruby|
          temp_code << "#{prefix}__temp_#{slot}__ = #{temp_ruby}\n"
        end
        @temp_assignments = nil
      end

      # Should now be at JUMP_IF_FALSE or JUMP_IF_TRUE
      inst = @instructions[@pc]
      return nil unless inst && (inst[0] == IL::JUMP_IF_FALSE || inst[0] == IL::JUMP_IF_TRUE)

      jump_type = inst[0]
      jump_target = inst[1]
      @pc += 1

      # Detect case/when OR pattern: multiple JUMP_IF_TRUE to same target
      # Pattern: CASE_COMPARE, JUMP_IF_TRUE target, LOAD_TEMP, CONST, CASE_COMPARE, JUMP_IF_TRUE target, ...
      # All pointing to CONST_TRUE, STORE_TEMP (success marker)
      if jump_type == IL::JUMP_IF_TRUE && is_case_when_or_pattern?(jump_target)
        return generate_case_when_or(cond_expr, jump_target, indent)
      end

      # Parse then branch (until jump_target or JUMP)
      then_code = String.new
      end_target = nil

      while @pc < @instructions.length && @pc < jump_target
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::JUMP
          end_target = inst[1]
          @pc += 1
          break
        when IL::HALT
          break
        else
          result = generate_statement(indent + 1)
          break if result.nil?
          then_code << result
        end
      end

      # Skip to jump_target if we haven't reached it
      @pc = jump_target if @pc < jump_target

      # Parse else branch (only if there IS an else - indicated by end_target being set)
      else_code = String.new

      if end_target
        while @pc < @instructions.length && @pc < end_target
          inst = @instructions[@pc]
          break if inst.nil?

          case inst[0]
          when IL::HALT
            break
          when IL::JUMP
            @pc += 1
            break
          when IL::LABEL
            @pc += 1
          else
            result = generate_statement(indent + 1)
            break if result.nil?
            else_code << result
          end
        end
      end

      # Generate code
      code = temp_code
      cond_ruby = cond_expr || "nil"

      if jump_type == IL::JUMP_IF_FALSE
        code << "#{prefix}if #{inline_truthy(cond_ruby)}\n"
      else
        code << "#{prefix}unless #{inline_truthy(cond_ruby)}\n"
      end

      code << then_code

      unless else_code.empty?
        code << "#{prefix}else\n"
        code << else_code
      end

      code << "#{prefix}end\n"
      code
    end

    # Detect case/when OR pattern: multiple conditions jumping to same success block
    # Target should be CONST_TRUE followed by STORE_TEMP (case/when success marker)
    def is_case_when_or_pattern?(jump_target)
      return false if jump_target >= @instructions.length

      target_inst = @instructions[jump_target]
      next_inst = @instructions[jump_target + 1]

      # Success block starts with CONST_TRUE, STORE_TEMP
      target_inst&.[](0) == IL::CONST_TRUE && next_inst&.[](0) == IL::STORE_TEMP
    end

    # Generate case/when with OR conditions (when 1, 2, 3 or when 1 or 2 or 3)
    def generate_case_when_or(first_cond, success_target, indent)
      prefix = INDENT[indent]
      conditions = [first_cond]
      case_end = nil

      # Collect remaining OR conditions that jump to the same target
      while @pc < success_target
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::LOAD_TEMP, IL::CONST_INT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_NIL
          # Start of next condition - build expression
          expr, _ = build_expression
          # Should now be at JUMP_IF_TRUE
          if @instructions[@pc]&.[](0) == IL::JUMP_IF_TRUE && @instructions[@pc][1] == success_target
            conditions << expr
            @pc += 1
          else
            break
          end
        when IL::JUMP
          # No more conditions, this is the "else" jump. Its target marks the
          # end of the whole case statement — used below to bound the success
          # body (otherwise the LAST when branch, having no following
          # LOAD_TEMP matched-flag check, would swallow statements after the
          # case: scope pops, trailing raw text, loop-back jumps, ...).
          case_end = inst[1]
          break
        else
          break
        end
      end

      # Skip to success target
      @pc = success_target

      # Skip CONST_TRUE and get the STORE_TEMP slot (success marker)
      success_slot = nil
      @pc += 1 if @instructions[@pc]&.[](0) == IL::CONST_TRUE
      if @instructions[@pc]&.[](0) == IL::STORE_TEMP
        success_slot = @instructions[@pc][1]
        @pc += 1
      end

      # Generate the combined OR condition
      cond_parts = conditions
      combined_cond = cond_parts.map { |c| "(#{inline_truthy(c)})" }.join(" || ")

      code = String.new
      code << "#{prefix}if #{combined_cond}\n"

      # Set the success flag to prevent else branch
      code << "#{prefix}  __temp_#{success_slot}__ = true\n" if success_slot

      # Parse success body until the end of the branch: a LOAD_TEMP
      # (next when's matched-flag check), a jump out of the case, or case_end
      while @pc < @instructions.length && (case_end.nil? || @pc < case_end)
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::LOAD_TEMP
          # This is checking the matched flag for else branch - done with body
          break
        when IL::HALT
          break
        when IL::JUMP
          # Forward jump to (or past) the end of the case — branch exit
          if case_end && inst[1] >= case_end
            @pc += 1
            break
          end
          result = generate_statement(indent + 1)
          break if result.nil?
          code << result
        else
          result = generate_statement(indent + 1)
          break if result.nil?
          code << result
        end
      end

      code << "#{prefix}end\n"
      code
    end

    # Inline simple filters to avoid Filters.apply dispatch (respond_to? + send)
    # Returns nil if the filter can't be inlined.
    # Register a frozen array constant for compile-time-known filter args.
    # Returns the variable name to use in generated code.
    # Deduplicates: same arg list → same constant.
    # Emit a standard filter dispatch call (cff, cf, or ccf)
    def emit_filter_dispatch(dispatcher, name, input, args, line)
      if args.empty?
        "_H.#{dispatcher}(#{name.inspect}, #{input}, LiquidIL::EMPTY_ARRAY, _S, #{@current_file_lit.inspect}, #{line})"
      elsif args.all? { |a| a.match?(/\A(?:-?\d+(?:\.\d+)?|"[^"]*")\z/) }
        frozen_name = register_frozen_array(args)
        "_H.#{dispatcher}(#{name.inspect}, #{input}, #{frozen_name}, _S, #{@current_file_lit.inspect}, #{line})"
      else
        "_H.#{dispatcher}(#{name.inspect}, #{input}, [#{args.join(', ')}], _S, #{@current_file_lit.inspect}, #{line})"
      end
    end

    # Process-wide loop-naming bases per partial source hash (append-only)
    @@partial_loop_bases = {}

    # Process-wide literal → constant-name registry (append-only). Names are
    # unique per literal so partial bodies cached across compilations keep
    # resolving to the right constant (see adopt_frozen_arrays).
    @@frozen_array_names = {}

    def register_frozen_array(args)
      key = "[#{args.join(', ')}]"
      name = (@@frozen_array_names[key] ||= "_fa#{@@frozen_array_names.size}__")
      @frozen_arrays[key] = name
      name
    end

    # Generate frozen array constant declarations for top of proc
    def generate_frozen_array_constants
      return "" if @frozen_arrays.empty?
      code = String.new
      @frozen_arrays.each do |literal, name|
        code << "  #{name} = #{literal}.freeze\n"
      end
      code
    end

    # Built-in filters that can never raise for any input (they coerce via
    # Utils.to_s / to_number, or rescue internally). These are safe to call
    # directly on _F — errors are impossible, so no dispatcher wrapper needed.
    #
    # Every OTHER known filter can raise FilterRuntimeError/ArgumentError
    # (to_integer, property selection, division by zero, ...) and MUST go
    # through _H.cff, which converts errors to an ErrorMarker so rendering
    # continues per-statement like reference Liquid. Unknown-at-compile-time
    # filters go through _H.cf (they may be custom filters registered at
    # render time, or unknown → input passthrough).
    SAFE_DIRECT_FILTERS = %w[
      append prepend capitalize downcase upcase t strip lstrip rstrip
      strip_html strip_newlines squish newline_to_br
      replace_first replace_last remove remove_first remove_last split
      escape escape_once url_encode base64_encode base64_url_safe_encode
      plus minus times abs ceil floor round at_least at_most
      size first last join reverse date json default
    ].each_with_object({}) { |n, h| h[n] = true }.freeze

    # Integer-literal argument (safe for inline .round(n) etc.)
    INT_LITERAL_RE = /\A-?\d+\z/

    def emit_filter_call(filter_name, input_ruby, args, filter_pc)
      # Identity optimizations: skip filters that are no-ops
      if (filter_name == "plus" && args.length == 1 && args[0] == "0") ||
         (filter_name == "minus" && args.length == 1 && args[0] == "0") ||
         (filter_name == "times" && args.length == 1 && args[0] == "1") ||
         (filter_name == "divided_by" && args.length == 1 && args[0] == "1")
        return input_ruby
      end

      # If an earlier filter in this chain went through a dispatcher, its
      # result may be an ErrorMarker. Keep the rest of the chain in
      # dispatcher-land so the marker short-circuits through untouched.
      chain_may_error = input_ruby.include?("_H.cf")

      if !chain_may_error && SAFE_DIRECT_FILTERS[filter_name]
        # Inline round/ceil/floor with integer-literal args: skip _F dispatch
        if SAFE_NUMERIC_FILTERS.match?("_F.#{filter_name}(") && args.length > 0 && args.all? { |a| a.match?(INT_LITERAL_RE) }
          return "(#{input_ruby} || 0).to_f.#{filter_name}(#{args.join(', ')})"
        elsif args.empty? && INLINE_SIMPLE_FILTERS[filter_name]
          # Inline simple filters: Utils.to_s(input).method
          # Use to_liquid_s (defined on all objects via core_ext) for correct
          # Liquid drop stringification. For Hash/Array, to_liquid_s uses the
          # legacy inspect format matching Liquid filter behavior.
          return "#{input_ruby}.to_liquid_s.#{filter_name}"
        elsif args.empty?
          return "_F.#{filter_name}(#{input_ruby})"
        else
          return "_F.#{filter_name}(#{input_ruby}, #{args.join(', ')})"
        end
      end

      line = line_for_pc(filter_pc)
      if Filters.valid_filter_methods[filter_name]
        emit_filter_dispatch("cff", filter_name, input_ruby, args, line)
      else
        emit_filter_dispatch("cf", filter_name, input_ruby, args, line)
      end
    end

    # Generate inline property lookup for const string keys (avoids __lookup__ lambda call)
    # Hot path: Hash string key lookup. Falls back to __lookup__ for other types.
    HASH_SPECIAL_KEYS = %w[size length first last].freeze

    # Inline lookup for loop variables (avoids _H.lf method call + is_a? check)
    LOOP_VAR_RE = /\A_i\d+__\z/

    def inline_lookup(obj_ruby, key)
      key_s = key.to_s
      if RuntimeHelpers::SPECIAL_KEYS[key_s]
        # Special keys (size/length/first/last) dispatch through the runtime:
        # lookup() knows the per-type semantics (String#first is a byteslice,
        # Arrays/Hashes differ, to_liquid must unwrap first). Inlining these
        # as ternary chains was both bigger (artifact bytes) and wrong for
        # non-collection receivers.
        "_H.lp(#{obj_ruby}, #{key_s.inspect})"
      elsif obj_ruby.match?(LOOP_VAR_RE)
        # Loop variable is always a Hash — inline the hash lookup directly
        # Skip symbol fallback for performance (string keys are the common case)
        "#{obj_ruby}[#{key_s.inspect}]"
      else
        "_H.lf(#{obj_ruby}, #{key_s.inspect})"
      end
    end

    # Generate inline output conversion (avoids __output_string__ lambda call)
    # Returns code that appends the expression value to _O
    # Patterns known to always return String — safe to skip output_append type dispatch
    STRING_RETURN_SUFFIXES = /\.(?:upcase|downcase|capitalize|strip|lstrip|rstrip|to_s\.upcase|to_s\.downcase|to_s\.capitalize|to_s\.strip|to_s\.lstrip|to_s\.rstrip|to_s\.reverse|gsub|sub|tr|squeeze|delete|chomp|chop|encode|freeze)\)?\z/
    # Direct filter calls that always return String — safe to skip output_append type dispatch
    STRING_FILTER_CALL = /\A_F\.(?:upcase|downcase|capitalize|strip|lstrip|rstrip|append|prepend|concat|join|handleize|escape|xml_escape|url_encode|url_decode|newline_to_br|truncate|truncatewords|base64_encode|base64_url_safe_encode|json)\(/
    STRING_RETURN_PATTERNS = /\A(?:\+?""|_U\.to_s\(|CGI\.escapeHTML\(|\("[^"]*"\s*\+\s*)/
    # Filters that always return Float/Integer — safe to use .to_s (no BigDecimal issue)
    SAFE_NUMERIC_FILTERS = /\A_F\.(?:round|ceil|floor)\(|\.(?:round|ceil|floor)\(.*\)\z/    # Filters that can be inlined: Utils.to_s(input).method(input) => input.to_s.method
    INLINE_SIMPLE_FILTERS = {'upcase' => true, 'downcase' => true, 'capitalize' => true, 'strip' => true, 'lstrip' => true, 'rstrip' => true}
    # Simple loop variable hash lookup — safe to use .to_s for output (Arrays are rare as hash values)
    SIMPLE_LOOP_LOOKUP = /\A_i\d+__\["\w+"\]\z/
    # Simple loop variable identifier — safe to use .to_s (scalars are most common)
    SIMPLE_LOOP_VAR = /\A_i\d+__\z/
    # Cache variable name for each simple filter (per-filter result cache)
    FILTER_CACHE = {
      'capitalize' => '_CAP__',
      'upcase' => '_UP__',
      'downcase' => '_DOWN__',
      'strip' => '_STRIP__',
      'lstrip' => '_LSTRIP__',
      'rstrip' => '_RSTRIP__'
    }

    def inline_output_append(expr_ruby, prefix, guard_interrupt: false)
      # When expression is known to return a String, skip the oa type dispatch
      # For simple inline filters, use a per-filter cache to avoid repeated method calls
      # e.g., input.to_s.capitalize -> (_CAP__ ||= {})[(_v = input.to_s)] ||= _v.capitalize
      cache_pattern = nil
      if (suffix_m = expr_ruby.match(/\.to_liquid_s\.(capitalize|upcase|downcase|strip|lstrip|rstrip)\z/))
        filter_name = suffix_m[1]
        if (cache_var = FILTER_CACHE[filter_name])
          # Extract the input expression (before .to_liquid_s)
          input_expr = expr_ruby.sub(/\.to_liquid_s\.(?:capitalize|upcase|downcase|strip|lstrip|rstrip)\z/, '')
          cache_pattern = "(#{cache_var}[(_v = #{input_expr}.to_liquid_s)] || (#{cache_var}[_v] = _v.#{filter_name}))"
        end
      end
      direct = cache_pattern || expr_ruby.match?(STRING_RETURN_SUFFIXES) || expr_ruby.match?(STRING_RETURN_PATTERNS) || expr_ruby.match?(STRING_FILTER_CALL)
      # For Float/Integer-returning filters, inline .to_s to avoid oa method call overhead
      numeric_safe = !direct && expr_ruby.match?(SAFE_NUMERIC_FILTERS)
      # Simple loop variable hash lookups and simple loop vars: use .to_s instead of oa
      simple_loop = !direct && !numeric_safe && (expr_ruby.match?(SIMPLE_LOOP_LOOKUP) || expr_ruby.match?(SIMPLE_LOOP_VAR))
      if guard_interrupt
        if direct
          output_expr = cache_pattern || expr_ruby
          "#{prefix}_O << #{output_expr} unless _S.has_interrupt?\n"
        elsif numeric_safe || simple_loop
          "#{prefix}_O << (#{expr_ruby}.to_s) unless _S.has_interrupt?\n"
        else
          "#{prefix}_H.oa(_O, #{expr_ruby}) unless _S.has_interrupt?\n"
        end
      else
        if direct
          output_expr = cache_pattern || expr_ruby
          "#{prefix}_O << #{output_expr}\n"
        elsif numeric_safe || simple_loop
          "#{prefix}_O << (#{expr_ruby}.to_s)\n"
        else
          "#{prefix}_H.oa(_O, #{expr_ruby})\n"
        end
      end
    end

    # Generate an inline truthy check expression (avoids lambda call overhead)
    # Uses || false to handle nil → false conversion, matching Liquid truthy semantics
    def inline_truthy(expr_ruby)
      # Ruby's if/unless already handles nil and false as falsy, matching Liquid semantics
      # So no need for || false — just use the expression directly
      # Simple expressions: identifier, __var__, or loop_var["key"]
      # Boolean expressions: comparisons, logical operators — already produce boolean result
      is_simple = expr_ruby =~ /\A[a-zA-Z_][a-zA-Z0-9_.]*\z/ || expr_ruby =~ /\A__\w+__\z/ || expr_ruby =~ /\A_[a-z]\d+__\["[^"]+"\]\z/
      is_boolean = expr_ruby.include?("&&") || expr_ruby.include?("||") || expr_ruby =~ /\)[><]=?\s*\d+\s*\)\z/ || expr_ruby =~ /\)[><]=?\s*\)\z/
      if is_boolean
        "(#{expr_ruby})"
      elsif is_simple
        # Unwrap drops via to_liquid_value (BooleanDrop with false should be falsy)
        "((_t = #{expr_ruby}); _t = _t.to_liquid_value; _t)"
      else
        # Complex expression - use _t temp to avoid double evaluation
        "((_t = #{expr_ruby}); _t = _t.to_liquid_value; _t)"
      end
    end

    # Evaluate generated Ruby code
    # Use TOPLEVEL_BINDING to avoid constant resolution issues in class context
    # Class-level ISeq binary cache: source hash → frozen binary string.
    # Avoids re-parsing Ruby source for identical generated code.
    # Capped at 1000 entries to bound memory; LRU eviction via simple clear.
    ISEQ_CACHE_MAX = 1000
    @@iseq_cache = {}

    # Cache for compiled partials — keyed by source hash
    PARTIAL_CACHE_MAX = 500
    @@partial_cache = {}

    def eval_ruby(source, partial_constants = nil)
      key = source.hash
      if (bin = @@iseq_cache[key])
        RubyVM::InstructionSequence.load_from_binary(bin).eval
      else
        iseq = RubyVM::InstructionSequence.compile(source, "(liquid_il_ruby)")
        @@iseq_cache.clear if @@iseq_cache.size >= ISEQ_CACHE_MAX
        @@iseq_cache[key] = iseq.to_binary.freeze
        iseq.eval
      end
    rescue SyntaxError => e
      nil
    end

    # Look up the ISeq binary for a given Ruby source string.
    # After eval_ruby, the binary is already in @@iseq_cache (free O(1) lookup).
    # Falls back to compiling + serializing if the cache was evicted.
    def self.iseq_binary_for(ruby_source)
      key = ruby_source.hash
      @@iseq_cache[key] || begin
        iseq = RubyVM::InstructionSequence.compile(ruby_source, "(liquid_il_structured)")
        bin = iseq.to_binary.freeze
        @@iseq_cache.clear if @@iseq_cache.size >= ISEQ_CACHE_MAX
        @@iseq_cache[key] = bin
        bin
      end
    end

    # Post-processing: hoist repeated hash lookups into temp variables.
    # When _i0__["tags"] appears in both a size/length check and a for-loop,
    # hoist the first lookup to a named temp and reuse it.
    def optimize_repeated_lookups(code)
      lines = code.lines
      lookups = []

      # Match: _i0__["tags"]&.size or _i0__['tags']&.length
      size_re = /(_\w+__\[(?:"[^"]+"|'[^"]+')\])\s*&\.(size|length)/

      lines.each_with_index do |line, i|
        m = line.match(size_re)
        if m
          lookups << { lookup: m[1], line: i, prop: m[2], indent: line[/\A\s*/], replaced: false }
        end
      end

      # Find for-loop collections that reuse the same lookup
      lines.each_with_index do |line, i|
        lookups.each do |r|
          next if r[:replaced] || i <= r[:line]
          if line.include?(r[:lookup]) && line.include?("__coll")
            r[:replaced] = true
            r[:coll_line] = i
          end
        end
      end

      # Apply in reverse to preserve line indices
      lookups.reverse_each do |r|
        next unless r[:replaced]
        key = r[:lookup][/"([^"]+)"/, 1] || r[:lookup]
        cache = "_cache_#{key}__"

        # Replace in for-loop: __coll1__ = _i0__["tags"] -> __coll1__ = _cache_tags__
        lines[r[:coll_line]] = lines[r[:coll_line]].sub("= #{r[:lookup]}", "= #{cache}")

        # Insert cache assignment before the if, update the inline lookup
        indent = r[:indent]
        old = lines[r[:line]]
        insert = "#{indent}#{cache} = #{r[:lookup]}\n"
        new_line = old.sub(r[:lookup] + "&.", cache + "&.")
        lines[r[:line]] = insert + new_line
      end

      lines.join
    end

  end

  class Compiler
    # Ruby compiler — the default (and only) compilation path.
    # Generates YJIT-friendly Ruby with native control flow.
    module Ruby
      # Active passes: [21]
      #   21: strip_labels - removes LABEL instructions (REQUIRED for Ruby compiler correctness)
      #   The Ruby compiler generates native Ruby control flow (if/for/while),
      #   so most IL optimizations (constant folding, instruction merging) don't
      #   provide benefit and only add compile overhead.
      # Skipped: [0..20, 22] - all passes except strip_labels.
      RUBY_SKIP_PASSES = ((0..22).to_a - [21]).freeze
      RUBY_DEFAULTS = { optimize: true, skip_passes: RUBY_SKIP_PASSES }.freeze

      def self.compile(source, context: nil, **options)
        opts = options.empty? ? RUBY_DEFAULTS : RUBY_DEFAULTS.merge(options)
        # Pass error_mode from context to compiler (default is :strict2)
        if context&.error_mode && context.error_mode != :lax
          opts = opts.merge(error_mode: context.error_mode)
        elsif !context
          # No context: use strict2 default
          opts = opts.merge(error_mode: :strict2)
        end
        warnings = []
        opts = opts.merge(warnings: warnings)
        compiler = Compiler.new(source, **opts)
        result = compiler.compile
        instructions = result[:instructions]
        spans = result[:spans]

        ruby_compiler = RubyCompiler.new(
          instructions,
          spans: spans,
          template_source: source,
          context: context
        )
        compiled_result = ruby_compiler.compile

        template = Template.new(source, instructions, spans, context, compiled_result)
        template.instance_variable_get(:@warnings).concat(warnings)
        template
      end
    end
  end
end
