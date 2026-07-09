# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Resolves, caches, plans, and emits static/dynamic partial calls. All
    # decisions operate on IL and CodeFragment metadata; generated Ruby is never
    # reparsed to infer scope or value semantics.
    module PartialEmitter
      private

      # Digest the index reports for `name` (memoized). Existence probe for the
      # external-partial decision and the identity baked into external call
      # sites / partial_dependencies. Never triggers a body fetch.
      def index_digest(name)
        return nil unless @partial_index
        @index_digests.fetch(name) { @index_digests[name] = @partial_index.digest(name) }
      end

      # Decide whether a static partial is compiled into THIS artifact (today's
      # inline/lambda path, needs a body fetch) or referenced EXTERNALLY (no
      # fetch; a provider supplies the compiled artifact at render time).
      #
      # Only active when a partial_index is present. A partial the index does not
      # know (digest nil) is NOT externalized — it falls through to the
      # file_system path (compile/inline, or the missing-partial error), so index
      # mode never hides a genuinely-missing partial. For known partials the
      # disposition is driven by the index's optional size/inline hooks:
      #   external?(name)  -> authoritative boolean, if provided
      #   inline?(name)    -> external = !inline?(name)
      #   bytesize(name)   -> inline only when known and <= INLINE_BODY_MAX_BYTES
      #   (none of these)  -> EXTERNAL: the body is not available without a fetch
      # Small partials keep today's inline path (their body IS fetched, once).
      def should_externalize?(name)
        idx = @partial_index
        return false unless idx
        return false if index_digest(name).nil?
        if idx.respond_to?(:external?)
          !!idx.external?(name)
        elsif idx.respond_to?(:inline?)
          !idx.inline?(name)
        elsif idx.respond_to?(:bytesize)
          sz = idx.bytesize(name)
          sz.nil? || sz > INLINE_BODY_MAX_BYTES
        else
          true
        end
      end

      # Resolve one static partial reference: externalize (no fetch) or compile
      # it into this artifact (today's path). Shared by every partial-scan site.
      def handle_static_partial(name)
        return if @partials[name]
        if should_externalize?(name)
          @partials[name] = { external: true, name: name, digest: index_digest(name) }
        elsif @context&.file_system
          compile_partial(name)
        end
      end

      # Every context/codegen input that can affect a cached partial body. The
      # partial's own name and source are framed separately by the caller.
      def compilation_cache_fingerprint
        return @compilation_cache_fingerprint if defined?(@compilation_cache_fingerprint)

        context_fingerprint = if @context&.respond_to?(:compilation_cache_fingerprint)
          @context.compilation_cache_fingerprint
        else
          "no-context"
        end
        @compilation_cache_fingerprint = [
          Artifact::COMPILER_ABI, context_fingerprint, @pretty, @optimize,
          @partial_index&.class&.name, @partial_index&.object_id
        ].freeze
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
          # Partial bodies bake the partial name into emitted error-location
          # literals, so cache identity must include the logical name as well as
          # source bytes.
          source_key = [
            Artifact::COMPILER_ABI, name.dup.freeze, partial_source.dup.freeze, compilation_cache_fingerprint
          ].freeze
          cached = CompilerCaches::PARTIAL[source_key]
          if cached && partial_cache_deps_valid?(cached, fs)
            @partials[name] = cached
            # The cached body references frozen-array constants and nested
            # partial lambdas from its original compilation — re-declare the
            # constants, replay its recorded lambda calls, and compile the
            # nested partials in this compilation too.
            @frozen_arrays.merge!(cached[:frozen_arrays]) if cached[:frozen_arrays]
            @lambda_called.merge(cached[:lambda_called]) if cached[:lambda_called]
            @required_helpers.merge(cached[:required_helpers]) if cached[:required_helpers]
            @required_filter_caches.merge(cached[:required_filter_caches]) if cached[:required_filter_caches]
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
          @partials[name] = { missing: true, name: name }
          return
        end

        # Compile the partial to IL. No error_mode: partials intentionally
        # parse :lax even under a :strict2 context (matches the liquid gem's
        # include behavior).
        begin
          compiler = LiquidIL::Compiler.new(source, optimize: true, skip_passes: PARTIAL_SKIP_PASSES)
          result = compiler.compile
        rescue LiquidIL::SyntaxError => e
          @partial_names_in_progress.delete(name)
          # Store the syntax error for runtime rendering
          @partials[name] = { syntax_error: e, source: source, name: name }
          return
        end
        instructions = result[:instructions]

        # Recursively compile to Ruby (sharing partials cache + frozen arrays)
        ruby_compiler = RubyCompiler.new(
          instructions,
          context: @context,
          partials: @partials,
          partial_names_in_progress: @partial_names_in_progress,
          hoist_data: result[:hoist],
          pretty: @pretty,
          partial_index: @partial_index
        )
        # Share frozen array usage map so partial constants are declared in the parent proc
        ruby_compiler.instance_variable_set(:@frozen_arrays, @frozen_arrays)
        # Partial bodies are process-cached as source fragments, so keep
        # their literals inline until that cache carries a relocatable constant
        # table. The root template still pools its own large raw literals.
        ruby_compiler.instance_variable_set(:@pool_literals, false)
        # Unique loop-naming base per partial source (process-wide, stable for
        # process-cache hits) — prevents loop-local collisions when this
        # body is inlined inside a caller's loop. Minting is mutex-guarded:
        # a size race here would hand two partials the same base.
        loop_key = [Artifact::COMPILER_ABI, name.dup.freeze, source.dup.freeze].freeze
        base = CodegenSymbols::PARTIAL_LOOP_BASES.intern(loop_key)
        ruby_compiler.instance_variable_set(:@loop_name_base, base)
        ruby_compiler.instance_variable_set(:@current_file_lit, name)
        child_lambda_called = Set.new
        ruby_compiler.instance_variable_set(:@lambda_called, child_lambda_called)

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
          name: name,
          source: source,
          instructions: instructions,
          compiled_body: partial_body,
          uses_cycles: partial_uses_cycles,
          uses_captures: partial_uses_captures || partial_uses_ifchanged,
          uses_ifchanged: partial_uses_ifchanged,
          deps: partial_dependency_hashes(instructions),
          lambda_called: child_lambda_called.to_a.freeze,
          required_helpers: ruby_compiler.instance_variable_get(:@required_helpers).to_a.freeze,
          required_filter_caches: ruby_compiler.instance_variable_get(:@required_filter_caches).to_a.freeze,
          frozen_arrays: ruby_compiler.instance_variable_get(:@frozen_arrays).dup.freeze,
          loop_name_base: base,
          scope_reads: ruby_compiler.instance_variable_get(:@effects).first.reads&.to_a&.freeze,
          uses_self: instructions.any? { |instruction| instruction[0] == IL::FIND_SELF }
        }
        @lambda_called.merge(child_lambda_called)
        @required_helpers.merge(@partials[name][:required_helpers])
        @required_filter_caches.merge(@partials[name][:required_filter_caches])

        # Cache for next compile of a template using this partial
        if source_key
          CompilerCaches::PARTIAL.store(source_key, @partials[name].dup)
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
          next if args["__dynamic_name__"]
          dep = i[1]
          info = @partials[dep]
          next unless info
          deps[dep] = info[:source].dup.freeze if info[:source]
          info[:deps]&.each { |k, v| deps[k] ||= v }
        end
        deps
      end

      def partial_cache_deps_valid?(cached, fs)
        deps = cached[:deps]
        return true if deps.nil? || deps.empty?
        deps.all? do |dep_name, source_hash|
          source = RuntimeHelpers.read_partial_source(fs, dep_name, @context)
          source == source_hash
        end
      end

      def partial_lambda_name(name)
        # Hex is an injective transformation of the complete name bytes and a
        # valid Ruby identifier alphabet. Punctuation replacement alone aliases
        # distinct names such as `a-b` and `a_b` inside one artifact.
        "__p#{name.b.unpack1("H*")}__"
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
            # Skip dynamic/invalid partials (handled at codegen)
            next if args["__dynamic_name__"]
            next if @partials[name]
            # handle_static_partial externalizes (index mode, no fetch) or, with a
            # file_system, compiles into this artifact (raises on mutual recursion).
            handle_static_partial(name)
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
              next if args["__dynamic_name__"]
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
      # decision is stable for process-cache-reused bodies.
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
        code << "\n  # Compiled partial lambdas\n" if @pretty
        # Forward-declare all lambda variables so mutual references work
        @partials.each do |name, info|
          next if info[:recursive] || info[:syntax_error] || info[:external]
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
          # runtime wrapper _H.ipc at the call sites — zero artifact bytes per
          # lambda for it, and no nested block ISeq inside the lambda.
          # Error locations inside the body are compile-time literals, so the
          # lambda carries no source/current-file state.
          # The scope arrives as the _S parameter (built by _H.ipc), which
          # shadows the outer proc's _S — partial bodies splice verbatim,
          # no scope-variable renaming.
          code << "  #{lambda_name} = ->(_S, _O, isolated, caller_line: 1, parent_cycle_state: nil) {\n"
          # Only allocate cycle/capture/ifchanged state when the partial actually uses them
          if info[:uses_cycles]
            code << "    _cs = isolated ? {} : (parent_cycle_state || {})\n"
          end
          if info[:uses_captures]
            code << "    _cst = []\n"
          end
          if info[:uses_ifchanged]
            code << "    _ics = {}\n"
          end
          code << indent_partial_body(info[:compiled_body], 4)
          code << "  }\n\n"
        end
        code
      end

      # Indent a compiled partial body for splicing. Both artifact lambdas and
      # inline isolated blocks bind a block-local `_S`, so bodies splice verbatim:
      # no generated-source scope or argument rewriting is required.
      def indent_partial_body(body, spaces)
        spaces = 0 unless @pretty
        indent = " " * spaces
        cache_key = [body.dup.freeze, spaces].freeze
        cached = CompilerCaches::INDENTED_PARTIAL_BODY[cache_key]
        return cached if cached

        result = spaces.zero? ? body : body.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l}" }.join
        CompilerCaches::INDENTED_PARTIAL_BODY.store(cache_key, result)
        result
      end


      # Emit a call site for an EXTERNAL partial (index mode). Mirrors the
      # lambda branch of generate_partial_call — same arg-hash build, include
      # scope publication, with/for handling, and interrupt propagation — but
      # routes through the render-time provider seam (_H.epc / external_partial_
      # lambda + rpf/ipf) instead of an in-artifact lambda. @pc and the
      # open-partial-call effect were already recorded by generate_partial_call.
      def generate_external_partial_call(inst, indent, isolated:)
        prefix = @indent[indent]
        name = inst[1]
        digest_lit = @partials[name][:digest].inspect
        provider = "_S.partial_provider"
        @partial_call_cycle_suffix ||= @uses_cycles ? ", _cs" : ""
        args = inst[2] || {}
        tag_type = isolated ? "render" : "include"
        line_num = inst[3] || 1

        with_expr = args["__with__"]
        for_expr = args["__for__"]
        as_alias = args["__as__"]
        item_var = as_alias || name

        code = String.new
        code << "#{prefix}# #{tag_type} '#{comment_safe(name)}' (external)\n" if @pretty

        unless isolated
          code << "#{prefix}if _S.disable_include\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"include usage is not allowed in this context\", file: #{@current_file_lit.inspect}, line: #{line_num})\n"
          code << "#{prefix}else\n"
          prefix = "  " * (indent + 1)
        end

        # include: look up with-value BEFORE keyword args mutate caller scope
        if with_expr && !isolated
          code << "#{prefix}__with_val__ = #{generate_var_lookup(with_expr)}\n"
        end

        code << "#{prefix}__partial_args__ = {}\n"
        args.each do |k, v|
          next if k.start_with?("__")
          if v.is_a?(Hash) && v[:__var__]
            var_path = v[:__var__]
            expr = var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path)
            code << "#{prefix}__partial_args__[#{k.inspect}] = #{expr}\n"
          else
            code << "#{prefix}__partial_args__[#{k.inspect}] = #{v.inspect}\n"
          end
          unless isolated
            code << "#{prefix}_S.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
          end
        end

        if for_expr
          expr = generate_var_lookup(for_expr)
          helper = isolated ? "rpf" : "ipf"
          cycle_arg = @uses_cycles ? ", _cs" : ""
          code << "#{prefix}__ext__ = _H.external_partial_lambda(#{provider}, #{name.inspect}, #{digest_lit}, _S)\n"
          code << "#{prefix}if __ext__\n"
          code << "#{prefix}  _H.#{helper}(__ext__, #{name.inspect}, #{item_var.inspect}, #{expr}, __partial_args__, _O, _S, #{line_num}#{cycle_arg})\n"
          code << "#{prefix}else\n"
          code << "#{prefix}  __partial_args__[#{item_var.inspect}] = #{expr}\n"
          code << "#{prefix}  _H.execute_dynamic_partial(#{name.inspect}, __partial_args__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
          code << "#{prefix}end\n"
        elsif with_expr
          if isolated
            code << "#{prefix}__with_val__ = #{generate_var_lookup(with_expr)}\n"
            code << "#{prefix}__partial_args__[#{item_var.inspect}] = __with_val__ unless __with_val__.nil?\n"
            code << "#{prefix}_H.epc(#{provider}, #{name.inspect}, #{digest_lit}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
          else
            code << "#{prefix}if __with_val__.is_a?(Array)\n"
            code << "#{prefix}  __with_val__.each do |_i_|\n"
            code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
            code << "#{prefix}    _S.assign(#{item_var.inspect}, _i_)\n"
            code << "#{prefix}    _H.epc(#{provider}, #{name.inspect}, #{digest_lit}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
            code << "#{prefix}  end\n"
            code << "#{prefix}else\n"
            code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __with_val__\n"
            code << "#{prefix}  _S.assign(#{item_var.inspect}, __with_val__)\n"
            code << "#{prefix}  _H.epc(#{provider}, #{name.inspect}, #{digest_lit}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
            code << "#{prefix}end\n"
          end
        else
          code << "#{prefix}_H.epc(#{provider}, #{name.inspect}, #{digest_lit}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
        end

        if !isolated && @loop_depth > 0
          code << "#{prefix}if _S.has_interrupt?\n"
          code << "#{prefix}  break if _S.pop_interrupt == :break\n"
          code << "#{prefix}  next\n"
          code << "#{prefix}end\n"
        end

        unless isolated
          code << "  " * indent << "end\n"
        end

        code
      end

      # {name => {digest:, disposition:}} for every static partial this template
      # references. disposition: :inline / :lambda (baked into THIS artifact —
      # its digest belongs in a composite cache key) or :external (a separate
      # per-file artifact a host must prefetch and a provider must supply).
      # Metadata only; computed after the body + lambdas so inline/lambda usage
      # is settled. Never consulted by emission.
      def compute_partial_dependencies
        deps = {}
        @partials.each do |name, info|
          if info[:external]
            disposition = :external
          elsif @inlined_partials.include?(name)
            disposition = :inline
          elsif @lambda_called.include?(name)
            disposition = :lambda
          else
            next
          end
          digest = info[:digest] || index_digest(name) || info[:source]&.hash
          deps[name] = { digest: digest, disposition: disposition }
        end
        deps
      end

      # Opcodes that can be emitted against explicit argument bindings without
      # consulting or mutating a Liquid Scope. This is a semantic IL allowlist,
      # not a generated-source pattern. Anything outside it uses the canonical
      # isolated-scope path.
      BOUND_PARTIAL_OPS = [
        IL::WRITE_RAW, IL::WRITE_VALUE, IL::WRITE_VAR, IL::WRITE_VAR_PATH,
        IL::CONST_NIL, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT,
        IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_RANGE, IL::CONST_EMPTY,
        IL::CONST_BLANK, IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_SELF, IL::LOOKUP_KEY,
        IL::LOOKUP_CONST_KEY, IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND,
        IL::COMPARE, IL::CASE_COMPARE, IL::CONTAINS, IL::BOOL_NOT,
        IL::IS_TRUTHY, IL::BOOL_AND, IL::BOOL_OR, IL::IF, IL::ELSE,
        IL::END_IF, IL::NEW_RANGE, IL::DUP, IL::POP, IL::BUILD_HASH, IL::HALT,
        IL::LABEL, IL::JUMP, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT,
        IL::FOR_INIT, IL::FOR_NEXT,
        IL::FOR_END, IL::PUSH_SCOPE, IL::POP_SCOPE, IL::PUSH_FORLOOP,
        IL::POP_FORLOOP, IL::POP_INTERRUPT
      ].each_with_object({}) { |opcode, out| out[opcode] = true }.freeze

      def bound_partial_scope_free?(instructions, bindings)
        return false if @has_resource_limits
        return false if instructions.any? { |instruction| instruction[0] == IL::PUSH_INTERRUPT }
        loop_names = {}
        instructions.each do |instruction|
          next unless instruction[0] == IL::FOR_INIT
          loop_names[instruction[1]] = true
          loop_names["forloop"] = true
          # offset:continue reads/writes the persistent scope offset table.
          return false if instruction[5]
        end

        instructions.all? do |instruction|
          opcode = instruction[0]
          if opcode == IL::ASSIGN_LOCAL
            next loop_names[instruction[1]]
          end
          next false unless BOUND_PARTIAL_OPS[opcode]
          if opcode == IL::FIND_SELF
            bindings.key?("self")
          elsif opcode == IL::FIND_VAR || opcode == IL::FIND_VAR_PATH ||
                opcode == IL::WRITE_VAR || opcode == IL::WRITE_VAR_PATH
            bindings.key?(instruction[1]) || loop_names[instruction[1]]
          else
            true
          end
        end
      end

      def bound_partial_body(info, bindings)
        # A partial that writes one of its argument names must read subsequent
        # values through its isolated scope, not the immutable caller temp.
        written = info[:instructions].each_with_object({}) do |instruction, names|
          case instruction[0]
          when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT,
               IL::FOR_INIT, IL::TABLEROW_INIT
            names[instruction[1]] = true
          end
        end
        effective_bindings = bindings.reject { |name, _| written[name] }
        needs_scope = !bound_partial_scope_free?(info[:instructions], effective_bindings)

        cacheable = info[:instructions].none? do |instruction|
          instruction[0] == IL::RENDER_PARTIAL || instruction[0] == IL::INCLUDE_PARTIAL
        end
        cache_key = if cacheable
          binding_key = effective_bindings.sort_by { |name, _| name }.flat_map do |name, fragment|
            [name, fragment.source, fragment.value_type]
          end
          [
            Artifact::COMPILER_ABI, info[:name].dup.freeze, info[:source].dup.freeze, @pretty,
            compilation_cache_fingerprint, *binding_key
          ].freeze
        end
        if cache_key
          cached = CompilerCaches::BOUND_PARTIAL_BODY[cache_key]
          if cached
            @required_helpers.merge(cached[:required_helpers])
            @required_filter_caches.merge(cached[:required_filter_caches])
            @frozen_arrays.merge!(cached[:frozen_arrays])
            return [cached[:body], needs_scope]
          end
        end

        emitter = RubyCompiler.new(
          info[:instructions], context: @context, partials: @partials,
          partial_names_in_progress: @partial_names_in_progress,
          pretty: @pretty, optimize: false, partial_index: @partial_index
        )
        emitter.instance_variable_set(:@scope_bindings, effective_bindings)
        emitter.instance_variable_set(:@current_file_lit, info[:name] || @current_file_lit)
        emitter.instance_variable_set(:@frozen_arrays, {})
        # Cached bound bodies must not carry parent-relative literal-pool indexes.
        emitter.instance_variable_set(:@pool_literals, false)
        emitter.instance_variable_set(:@loop_name_base, info[:loop_name_base] || 0)
        body = emitter.send(:generate_body)
        helpers = emitter.instance_variable_get(:@required_helpers)
        filter_caches = emitter.instance_variable_get(:@required_filter_caches)
        frozen_arrays = emitter.instance_variable_get(:@frozen_arrays)
        @required_helpers.merge(helpers)
        @required_filter_caches.merge(filter_caches)
        @frozen_arrays.merge!(frozen_arrays)
        if cache_key
          entry = {
            body: body.freeze,
            required_helpers: helpers.to_a.freeze,
            required_filter_caches: filter_caches.to_a.freeze,
            frozen_arrays: frozen_arrays.dup.freeze,
          }.freeze
          CompilerCaches::BOUND_PARTIAL_BODY.store(cache_key, entry)
        end
        [body, needs_scope]
      end

      def partial_arg_local(partial_name, argument_name)
        key = [partial_name, argument_name]
        @partial_arg_locals[key] ||= "_pa#{@partial_arg_locals.length}__"
      end

      def literal_fragment(value)
        type = case value
        when String then :string
        when Numeric then :numeric
        when TrueClass, FalseClass then :boolean
        else :unknown
        end
        CodeFragment.new(value.inspect, value_type: type)
      end

      # Generate a partial call (render or include)
      def generate_partial_call(inst, indent, isolated:)
        @pc += 1
        record_open_partial_call unless isolated
        prefix = @indent[indent]
        name = inst[1]
        # Cycle state suffix: only include if any partial uses cycles
        @partial_call_cycle_suffix ||= @uses_cycles ? ", _cs" : ""
        args = inst[2] || {}
        tag_type = isolated ? "render" : "include"
        line_num = inst[3] || 1

        if args["__dynamic_name__"]
          return generate_dynamic_partial(inst, indent, isolated: isolated)
        end
        # External partial (index mode): the body is not in this artifact; emit a
        # render-time provider call. Handled before the no-file-system guard —
        # index mode may supply partials with no file_system at all.
        if @partials[name]&.[](:external)
          return generate_external_partial_call(inst, indent, isolated: isolated)
        end
        if !@context&.file_system
          annot = @pretty ? "#{prefix}# #{tag_type} '#{comment_safe(name)}' (no file system)\n" : ""
          return "#{annot}#{prefix}_O << #{lit("Liquid error (line #{line_num}): This liquid context does not allow includes.")}\n"
        end

        # Missing/syntax-error partials use dynamic execution to surface the
        # error at render time, honoring render_errors/render! semantics.
        if @partials[name]&.[](:missing) || @partials[name]&.[](:syntax_error)
          code = String.new
          reason = @partials[name]&.[](:missing) ? "missing" : "syntax error"
          code << "#{prefix}# #{tag_type} '#{comment_safe(name)}' (#{reason})\n" if @pretty
          code << "#{prefix}__dyn_assigns__ = {}\n"
          code << "#{prefix}_H.execute_dynamic_partial(#{name.inspect}, __dyn_assigns__, _O, _S, isolated: #{isolated}, tag_type: #{tag_type.inspect}, caller_line: #{line_num})\n"
          return code
        end

        # Recursive partials use runtime resolution
        if @partials[name]&.[](:recursive)
          code = String.new
          code << "#{prefix}# #{tag_type} '#{comment_safe(name)}' (recursive — runtime resolution)\n" if @pretty
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
        code << "#{prefix}# #{tag_type} '#{comment_safe(name)}'\n" if @pretty

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

        # Build the partial's render-time argument hash. This contains values from
        # the CURRENT render only and is rebuilt for every invocation; it is never
        # persisted in the template artifact. For include, resolve `with` before
        # keyword args mutate the shared caller scope.
        if with_expr && !isolated
          expr = generate_var_lookup(with_expr)
          code << "#{prefix}__with_val__ = #{expr}\n"
        end

        @inlined_partials << name if inline_partial
        inline_setup = nil
        inline_bound_body = nil
        inline_needs_scope = false
        inline_bindings = nil
        if inline_partial
          bindings = {}
          setup = String.new
          @inline_scope_counter += 1
          referenced_args = @partials[name][:scope_reads]
          args.each do |k, v|
            next if k.start_with?("__")
            next if referenced_args && !referenced_args.include?(k) && !(k == "self" && @partials[name][:uses_self])
            source_fragment = if v.is_a?(Hash) && v[:__var__]
              var_path = v[:__var__]
              CodeFragment.new(var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path))
            else
              literal_fragment(v)
            end
            local = partial_arg_local(name, k)
            setup << "#{prefix}#{local} = #{source_fragment.source}\n"
            bindings[k] = CodeFragment.new(local, value_type: source_fragment.value_type)
          end
          inline_bound_body, inline_needs_scope = bound_partial_body(@partials[name], bindings)
          inline_setup = setup
          inline_bindings = bindings
        end

        if inline_partial && inline_needs_scope
          code << inline_setup
          code << "#{prefix}__partial_args__ = {}\n"
          inline_bindings.each do |key, fragment|
            code << "#{prefix}__partial_args__[#{key.inspect}] = #{fragment.source}\n"
          end
        elsif !inline_partial
          code << "#{prefix}__partial_args__ = {}\n"
          args.each do |k, v|
            next if k.start_with?("__")
            if v.is_a?(Hash) && v[:__var__]
              var_path = v[:__var__]
              expr = var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path)
              code << "#{prefix}__partial_args__[#{k.inspect}] = #{expr}\n"
            else
              code << "#{prefix}__partial_args__[#{k.inspect}] = #{v.inspect}\n"
            end
            code << "#{prefix}_S.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n" unless isolated
          end
        end

        if for_expr
          # Render once per item in collection — the collection-type dispatch
          # (Array/Range/enumerable/nil/scalar), per-item forloop drops, and
          # include's scope publication + interrupt check all live in the
          # _H.rpf/_H.ipf drivers, not at every call site.
          expr = generate_var_lookup(for_expr)
          helper = isolated ? "rpf" : "ipf"
          cycle_arg = @uses_cycles ? ", _cs" : ""
          code << "#{prefix}_H.#{helper}(#{lambda_name}, #{name.inspect}, #{item_var.inspect}, #{expr}, __partial_args__, _O, _S, #{line_num}#{cycle_arg})\n"
        elsif with_expr
          # Render with a specific value
          # For isolated (render), we lookup here. For include, we already looked up above.
          if isolated
            expr = generate_var_lookup(with_expr)
            code << "#{prefix}__with_val__ = #{expr}\n"
            code << "#{prefix}__partial_args__[#{item_var.inspect}] = __with_val__ unless __with_val__.nil?\n"
            code << "#{prefix}_H.ipc(#{lambda_name}, #{name.inspect}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
          else
            # For include, __with_val__ was already looked up BEFORE keyword args modified scope
            # Assign the with-value to the current scope so the partial can see it
            code << "#{prefix}if __with_val__.is_a?(Array)\n"
            code << "#{prefix}  __with_val__.each do |_i_|\n"
            code << "#{prefix}    __partial_args__[#{item_var.inspect}] = _i_\n"
            code << "#{prefix}    _S.assign(#{item_var.inspect}, _i_)\n"
            code << "#{prefix}    _H.ipc(#{lambda_name}, #{name.inspect}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
            code << "#{prefix}  end\n"
            code << "#{prefix}else\n"
            code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __with_val__\n"
            code << "#{prefix}  _S.assign(#{item_var.inspect}, __with_val__)\n"
            code << "#{prefix}  _H.ipc(#{lambda_name}, #{name.inspect}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
            code << "#{prefix}end\n"
          end
        else
          # Simple render
          # For simple isolated partials, inline the body to avoid lambda call overhead
          if inline_partial && !inline_needs_scope
            code << inline_setup << inline_bound_body
          elsif inline_partial
            # Rebind the compiler-owned scope local for the duration of the
            # verbatim inline body, then restore it. This keeps one flat ISeq
            # and requires no generated-source rewriting.
            scope_temp = "__caller_scope_#{@loop_name_base + @inline_scope_counter}__"
            @inline_scope_counter += 1
            code << "#{prefix}#{scope_temp} = _S; _S = _S.isolated_with(__partial_args__)\n"
            code << inline_bound_body
            code << "#{prefix}_S = #{scope_temp}\n"
          else
            code << "#{prefix}_H.ipc(#{lambda_name}, #{name.inspect}, __partial_args__, _O, _S, #{isolated}, #{line_num}#{@partial_call_cycle_suffix})\n"
          end
        end

        # After include: propagate interrupts (break/continue) from partial to caller's loop
        if !isolated && @loop_depth > 0
          code << "#{prefix}if _S.has_interrupt?\n"
          code << "#{prefix}  break if _S.pop_interrupt == :break\n"
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
      def generate_dynamic_partial(inst, indent, isolated:)
        prefix = @indent[indent]
        args = inst[2] || {}
        tag_type = isolated ? "render" : "include"
        line_num = inst[3] || 1

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
            "#{prefix}      break if _S.pop_interrupt == :break\n" \
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

    end
  end
end
