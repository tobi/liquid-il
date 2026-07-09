# frozen_string_literal: true

require_relative "runtime_helpers"
require_relative "ruby_compiler/analysis"
require_relative "ruby_compiler/cache_store"
require_relative "ruby_compiler/code_fragment"
require_relative "ruby_compiler/expression"
require_relative "ruby_compiler/expression_helpers"
require_relative "ruby_compiler/filter"
require_relative "ruby_compiler/loop"
require_relative "ruby_compiler/output"
require_relative "ruby_compiler/partial"
require_relative "ruby_compiler/program"
require_relative "ruby_compiler/statement"
require_relative "ruby_compiler/statement_dedup"
require_relative "ruby_compiler/symbol_table"

module LiquidIL
  # Compiles IL to Ruby with native control flow (if/else, each blocks)
  # and direct expressions (no stack). This generates YJIT-friendly code.
  class RubyCompiler
    extend ProgramSerialization

    include AnalysisEmitter
    include CompilationCache
    include ExpressionEmitter
    include ExpressionHelpers
    include FilterEmitter
    include LoopEmitter
    include OutputEmitter
    include PartialEmitter
    include StatementDedup
    include StatementEmitter

    # IL passes skipped when compiling a partial's IL for the Ruby backend.
    # Kept: the cheap peephole passes (const folding/writes, path collapsing,
    # noop removal, raw-write merging, fuse_write_var) that shrink the IL the
    # codegen walks. Skipped: global-analysis passes whose work the generated
    # Ruby makes redundant. (strip_labels here is inert — label stripping runs
    # in Compiler#compile keyed on the globally enabled set, not skip_passes —
    # but is listed to keep this the exact complement of the kept peepholes.)
    PARTIAL_SKIP_PASSES = Passes.resolve(%i[
      remove_redundant_is_truthy remove_jump_to_next_label remove_unreachable
      merge_raw_writes_2 fold_const_captures remove_empty_raw_writes
      propagate_constants fold_const_filters_2 hoist_loop_invariants
      cache_repeated_lookups
      strip_labels remove_interrupt_checks
    ])

    class CompilationResult
      attr_reader :proc, :source, :can_compile, :partials, :partial_constants,
                  :partial_dependencies

      def initialize(proc:, source:, can_compile:, partials: {}, partial_constants: nil,
                     partial_dependencies: nil)
        @proc = proc
        @source = source
        @can_compile = can_compile
        @partials = partials
        @partial_constants = partial_constants
        @partial_dependencies = partial_dependencies
      end
    end

    # Comparison operator mapping
    COMPARE_OPS = { eq: "==", ne: "!=", lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    # Numeric-only operators that can be inlined (no to_liquid_value needed for simple numeric comparisons)
    NUMERIC_COMPARE_OPS = { lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    # Cached indent strings to avoid repeated "  " * n allocations
    INDENT = Array.new(20) { |i| ("  " * i).freeze }.freeze
    # Production (non-pretty) indent table: every level is "". compact_source
    # strips all leading whitespace before the ISeq is compiled, so emitted
    # indentation is pure human-readable formatting — skipping it avoids the
    # per-line string building and the loop-body re-indent gsubs. Same length as
    # INDENT so any INDENT[indent+k] index resolves identically.
    EMPTY_INDENT = Array.new(20) { "" }.freeze

    def initialize(instructions, context: nil, partials: nil, partial_names_in_progress: nil, hoist_data: nil, pretty: false, optimize: true, partial_index: nil)
      @instructions = instructions
      @context = context
      # Digest index (name -> content_digest, plus optional bytesize/inline?/
      # external? hooks) for the external-partial compile mode. When present,
      # partials the index knows about are resolved to EXISTENCE + identity
      # WITHOUT a body fetch, and large/opaque ones become EXTERNAL provider
      # call sites instead of being inlined/embedded. nil => today's behavior
      # exactly (every static partial fetched + inlined/embedded); emission is
      # byte-identical in that case.
      @partial_index = partial_index || context&.partial_index
      # {name => {digest:, disposition:}} surfaced on the result/Template so a
      # host can build a composite cache key and know which external artifacts
      # to prefetch. Metadata only — never affects emission.
      @partial_dependencies = {}
      # Memoized index.digest(name) lookups (also used as emitted literals).
      @index_digests = {}
      # Optimizer-provided hoisted-lookup census [counts, written, blocked],
      # or nil to fall back to a fresh IL walk (compute_hoisted_lookups).
      @hoist_data = hoist_data
      # Pretty mode emits human-readable indentation and comments into the
      # generated source (for compiled_source / bin/liquidil). The production
      # default skips both — compact_source discards them before the ISeq is
      # built, so the compiled proc is byte-identical either way.
      @pretty = pretty
      @indent = pretty ? INDENT : EMPTY_INDENT
      # Backend-level optimizations (currently the statement-run dedup) are
      # gated on this so `optimize: false` yields a faithful un-deduped baseline.
      @optimize = optimize
      @loop_depth = 0 # Track nested loop depth for parentloop support
      @inline_scope_counter = 0
      @partial_arg_locals = {}
      # Compile-time current file (nil for the main template, the partial
      # name inside partial compilations — see compile_partial). Baked into
      # emitted error-location literals — no runtime tracking in the code.
      @current_file_lit = nil
      # Loop-local naming offset. 0 for the main template; partials get a
      # unique base (compile_partial) so their loop locals (__i0__, _fl0__,
      # _c0__, ...) never collide with a call site's when inlined.
      @loop_name_base = 0
      @has_resource_limits = !!context&.resource_limits
      @partials = partials || {}
      @partial_names_in_progress = partial_names_in_progress || Set.new
      @uses_interrupts = detect_uses_interrupts
      # Maps Liquid variable names to Ruby local variable names inside for loops
      # e.g. "i" => "_i0__", "forloop" => "_fl0__"
      @loop_var_aliases = {}
      @hoisted_lookups = EMPTY_HOISTS
      @effects = [Effects.new]
      # Frozen array constants used by this compilation. Names come from a
      # bounded monotonic SymbolTable, so cached bodies never alias reused names.
      @frozen_arrays = {}
      # Partials that some emitted body actually lambda-calls. Recorded at
      # emission time (and stored with cached bodies) so generate_partial_lambdas
      # emits exactly the lambdas that are needed — no decision re-derivation.
      @lambda_called = Set.new
      # Track which partials are fully inlined (no lambda call sites)
      @inlined_partials = Set.new
      # Compile-time constants passed separately from the ISeq on every render.
      # These are immutable template literals only — never assigns or values
      # observed at render time. Keeping large literals outside the ISeq lowers
      # cold load_from_binary cost while one loaded proc remains fully reusable.
      @partial_constants = []
      @literal_indices = {}
      @pool_literals = true
      @required_helpers = Set.new
      @required_filter_caches = Set.new
      # Deduplicated statement-run lambdas registered by the StatementDedup pass
      # (main template body only; see dedup_statement_runs).
      @sequences = []
    end

    # Check if template uses break/continue
    def detect_uses_interrupts
      @instructions.any? { |inst| inst[0] == IL::PUSH_INTERRUPT }
    end

    def compile
      code = generate_ruby
      compiled_proc = eval_ruby(code)
      raise "Failed to eval generated Ruby code" unless compiled_proc

      CompilationResult.new(
        proc: compiled_proc,
        source: code,
        can_compile: true,
        partial_constants: @partial_constants.empty? ? nil : @partial_constants.freeze,
        partial_dependencies: @partial_dependencies.empty? ? nil : @partial_dependencies.freeze,
      )
    end

    private

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
          next if args["__dynamic_name__"]
          next if @partials[name] && (@partials[name][:compiled_body] || @partials[name][:external])
          handle_static_partial(name)
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

      # Dedup repeated statement runs into artifact-local lambdas BEFORE hoisting
      # (so CALL_SEQ arg operands contribute reads/writes to the hoist scan) and
      # before codegen (so the body emits CALL_SEQ sites). Rewrites @instructions
      # and populates @sequences.
      dedup_statement_runs

      # Decide hoisted lookups from the IL before any code exists —
      # emission consults @hoisted_lookups through scope_lookup. The optimizer
      # already walked every instruction and handed us the census (@hoist_data);
      # only re-walk when it didn't run (optimize: false).
      @hoisted_lookups = if @hoist_data
        derive_hoisted_lookups(*@hoist_data)
      else
        compute_hoisted_lookups
      end

      # Sequence lambda definitions (emitted below, near the frozen-array
      # constants). Generated before the body so its per-site effects merge and
      # inline decisions are already settled.
      seq_code = generate_sequence_lambdas

      # Generate body first so inlining info is available for partial lambdas
      body_code = generate_body  # also sets @uses_cycles, @uses_captures, @uses_ifchanged, @inlined_partials
      partial_code = generate_partial_lambdas  # skips lambda body for fully inlined partials

      # Surface per-partial disposition (inline/lambda/external) + digests for
      # composite cache keying / external prefetch. Metadata only.
      @partial_dependencies = compute_partial_dependencies

      code = String.new
      has_pc = !@partial_constants.empty?
      code << "# frozen_string_literal: true\n"
      if has_pc
        code << "proc do |_S, _pc|\n"
      else
        code << "proc do |_S|\n"
      end
      code << "  _H = LiquidIL::RuntimeHelpers\n"
      code << "  _U = LiquidIL::Utils\n" if @required_helpers.include?(:utils)
      code << "  _F = LiquidIL::Filters\n" if @required_helpers.include?(:filters)
      # Frozen array constants and sequence lambdas must be declared before
      # partial lambdas and the body (all are closures that capture them).
      code << generate_frozen_array_constants
      code << seq_code
      code << partial_code
      code << "  _O = +\"\"\n"
      # Pre-initialize filter caches to avoid ||= check per iteration
      @required_filter_caches.each do |cache_var|
        code << "  #{cache_var} = {}\n"
      end
      code << "  _cs = {}\n" if @uses_cycles
      code << "  _cst = []\n" if @uses_captures || @uses_ifchanged
      code << "  _ics = {}\n" if @uses_ifchanged
      code << "\n"
      @hoisted_lookups.each do |name, local|
        code << "  #{local} = _S.lookup(#{name.inspect})\n"
      end
      code << body_code
      code << "\n  _O\n"
      code << "end\n"
      code
    end


  end

  class Compiler
    # Ruby compiler — the default (and only) compilation path.
    # Generates YJIT-friendly Ruby with native control flow.
    module Ruby
      # Optimization is on by default: the folding peepholes run because they
      # do work codegen cannot (const filter calls, static branch elimination,
      # capture folding) and shrink the emitted ISeq. Skipped: the VM-era
      # global analyses (hoisting/lookup-caching insert DUP/STORE_TEMP locals
      # that make the generated native Ruby worse), jump cleanups that native
      # control flow makes moot, and remove_interrupt_checks (the backend
      # no-emits those opcodes anyway). strip_labels is REQUIRED for Ruby
      # compiler correctness.
      RUBY_SKIP_PASSES = Passes.resolve(%i[
        remove_redundant_is_truthy remove_jump_to_next_label remove_unreachable
        merge_raw_writes_2 hoist_loop_invariants cache_repeated_lookups
        remove_interrupt_checks
      ]).freeze
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
        # pretty is a backend-only concern (human-readable source); keep it out
        # of the IL compiler's options.
        pretty = opts[:pretty] || false
        opts = opts.merge(warnings: warnings).except(:pretty)
        compiler = Compiler.new(source, **opts)
        result = compiler.compile
        instructions = result[:instructions]

        ruby_compiler = RubyCompiler.new(
          instructions,
          context: context,
          hoist_data: result[:hoist],
          pretty: pretty,
          optimize: opts.fetch(:optimize, true),
          # Direct compile option wins over the context's; nil => today's path.
          partial_index: options[:partial_index] || context&.partial_index
        )
        if options[:template_name]
          ruby_compiler.instance_variable_set(:@current_file_lit, options[:template_name])
        end
        compiled_result = ruby_compiler.compile

        template = Template.new(source, instructions, context, compiled_result)
        template.instance_variable_get(:@warnings).concat(warnings)
        template
      end
    end
  end
end
