# frozen_string_literal: true

module LiquidIL
  # Compiles IL to Ruby with native control flow (if/else, each blocks)
  # and direct expressions (no stack). This generates YJIT-friendly code.
  class StructuredCompiler
    OUTPUT_CAPACITY = 8192

    class CompilationResult
      attr_reader :proc, :source, :can_compile, :partials

      def initialize(proc:, source:, can_compile:, partials: {})
        @proc = proc
        @source = source
        @can_compile = can_compile
        @partials = partials
      end
    end

    # Expression node for reconstructed expressions
    # Using Struct instead of Data.define to avoid Ruby 4.0 segfaults with deep recursion
    # pc: optional instruction index for error line tracking (used by filters)
    Expr = Struct.new(:type, :value, :children, :pc, keyword_init: true) do
      def initialize(type:, value: nil, children: [], pc: nil)
        super
      end
    end

    # Comparison operator mapping
    COMPARE_OPS = { eq: "==", ne: "!=", lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    def initialize(instructions, spans: nil, template_source: nil, context: nil, partials: nil, partial_names_in_progress: nil)
      @instructions = instructions
      @spans = spans || []
      @template_source = template_source
      @context = context
      @loop_depth = 0 # Track nested loop depth for parentloop support
      @partials = partials || {}
      @partial_names_in_progress = partial_names_in_progress || Set.new
      @uses_interrupts = detect_uses_interrupts
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
      raise "Structured compilation not supported for this template: #{compilation_blockers.join(', ')}" unless can_compile?

      code = generate_ruby
      compiled_proc = eval_ruby(code)
      raise "Failed to eval generated Ruby code" unless compiled_proc

      CompilationResult.new(
        proc: compiled_proc,
        source: code,
        can_compile: true
      )
    end

    # Compile a partial and store it for later code generation
    def compile_partial(name)
      return if @partials[name]
      # Mutual recursion detected - can't compile this to lambdas
      if @partial_names_in_progress.include?(name)
        raise "Mutual recursion detected: #{name}"
      end

      @partial_names_in_progress.add(name)

      # Load the partial source
      fs = @context&.file_system
      source = if fs.respond_to?(:read_template_file)
                 fs.read_template_file(name) rescue nil
               elsif fs.respond_to?(:read)
                 fs.read(name)
               end

      unless source
        @partial_names_in_progress.delete(name)
        raise "Cannot load partial '#{name}'"
      end

      # Compile the partial to IL
      begin
        compiler = LiquidIL::Compiler.new(source, optimize: true)
        result = compiler.compile
      rescue LiquidIL::SyntaxError => e
        @partial_names_in_progress.delete(name)
        raise "Partial '#{name}' has syntax error: #{e.message}"
      end
      instructions = result[:instructions]
      spans = result[:spans]

      # Recursively compile to structured Ruby (sharing partials cache)
      structured_compiler = StructuredCompiler.new(
        instructions,
        spans: spans,
        template_source: source,
        context: @context,
        partials: @partials,
        partial_names_in_progress: @partial_names_in_progress
      )

      # Check if this partial can be compiled
      unless structured_compiler.send(:can_compile?)
        @partial_names_in_progress.delete(name)
        raise "Partial '#{name}' cannot be compiled (unsupported features)"
      end

      # Scan for nested partials first (this populates @partials with all nested partials)
      structured_compiler.send(:scan_and_compile_partials)

      # Generate code for this partial's body
      structured_compiler.instance_variable_set(:@pc, 0)
      partial_body = structured_compiler.send(:generate_body)

      @partials[name] = {
        source: source,
        instructions: instructions,
        spans: spans,
        compiled_body: partial_body
      }

      @partial_names_in_progress.delete(name)
    end

    def partial_lambda_name(name)
      "__partial_#{name.gsub(/[^a-zA-Z0-9_]/, '_')}__"
    end

    private

    # Check if we can compile this template
    def can_compile?
      compilation_blockers.empty?
    end

    def compilation_blockers
      blockers = []
      has_include = false
      has_for_loop = false

      @instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          args = inst[2] || {}
          blockers << "dynamic partial name" if args["__dynamic_name__"]
          blockers << "invalid partial name" if args["__invalid_name__"]
          blockers << "no file system for partials" unless @context&.file_system
          has_include = true if inst[0] == IL::INCLUDE_PARTIAL
        when IL::FOR_INIT, IL::TABLEROW_INIT
          has_for_loop = true
        end
      end

      # If we have both includes and for loops, check if any partial uses interrupts
      # Break/continue in partials doesn't propagate correctly with throw/catch
      if has_include && has_for_loop
        @instructions.each do |inst|
          if inst[0] == IL::INCLUDE_PARTIAL
            name = inst[1]
            args = inst[2] || {}
            next if args["__dynamic_name__"] || args["__invalid_name__"]
            if partial_uses_interrupts?(name)
              blockers << "partial '#{name}' uses interrupts inside for loop"
            end
          end
        end
      end

      blockers
    end

    # Check if a partial uses interrupts (break/continue)
    def partial_uses_interrupts?(name, visited = Set.new)
      return false if visited.include?(name)
      visited.add(name)

      fs = @context&.file_system
      return false unless fs

      source = if fs.respond_to?(:read_template_file)
                 fs.read_template_file(name) rescue nil
               elsif fs.respond_to?(:read)
                 fs.read(name)
               end

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
      # First pass: scan for partials and compile them
      scan_and_compile_partials

      code = String.new
      code << "# frozen_string_literal: true\n"
      code << "proc do |__scope__, __spans__, __template_source__|\n"
      code << generate_helpers
      code << generate_partial_lambdas
      code << "  __output__ = String.new(capacity: #{OUTPUT_CAPACITY})\n"
      code << "  __current_file__ = nil\n"
      code << "  __cycle_state__ = {}\n"
      code << "  __capture_stack__ = []\n"
      code << "  __ifchanged_state__ = {}\n\n"
      code << generate_body
      code << "\n  __output__\n"
      code << "end\n"
      code
    end

    # Scan instructions for partials and compile them
    def scan_and_compile_partials
      @instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          name = inst[1]
          args = inst[2] || {}
          # Skip dynamic/invalid partials (handled by can_compile?)
          next if args["__dynamic_name__"] || args["__invalid_name__"]
          next if @partials[name]
          # compile_partial will raise if mutual recursion detected
          compile_partial(name)
        end
      end
    end

    # Generate lambda definitions for compiled partials
    def generate_partial_lambdas
      return "" if @partials.empty?

      code = String.new
      code << "\n  # Compiled partial lambdas\n"
      @partials.each do |name, info|
        lambda_name = partial_lambda_name(name)
        code << "  #{lambda_name} = ->(assigns, __output__, __parent_scope__, isolated, caller_line: 1, parent_cycle_state: nil) {\n"
        code << "    __prev_file__ = __parent_scope__.current_file\n"
        code << "    __parent_scope__.current_file = #{name.inspect}\n"
        code << "    __parent_scope__.push_render_depth\n"
        code << "    begin\n"
        code << "      if __parent_scope__.render_depth_exceeded?(strict: !isolated)\n"
        code << "        raise LiquidIL::RuntimeError.new(\"Nesting too deep\", file: #{name.inspect}, line: caller_line)\n"
        code << "      end\n"
        code << "      __partial_scope__ = isolated ? __parent_scope__.isolated : __parent_scope__\n"
        code << "      assigns.each { |k, v| __partial_scope__.assign(k, v) }\n"
        code << "      __spans__ = #{info[:spans].inspect}\n"
        code << "      __template_source__ = #{info[:source].inspect}\n"
        code << "      __current_file__ = #{name.inspect}\n"
        # Share cycle state for includes (non-isolated), fresh for renders
        code << "      __cycle_state__ = isolated ? {} : (parent_cycle_state || {})\n"
        code << "      __capture_stack__ = []\n"
        code << "      __ifchanged_state__ = {}\n"
        code << indent_partial_body(info[:compiled_body], 6)
        code << "    rescue LiquidIL::RuntimeError => e\n"
        code << "      raise unless __parent_scope__.render_errors\n"
        code << "      __output__ << (e.partial_output || \"\")\n"
        code << "      location = e.file ? \"\#{e.file} line \#{e.line}\" : \"line \#{e.line}\"\n"
        code << "      __output__ << \"Liquid error (\#{location}): \#{e.message}\"\n"
        code << "    rescue LiquidIL::FilterRuntimeError => e\n"
        code << "      raise unless __parent_scope__.render_errors\n"
        code << "      __output__ << \"Liquid error (#{name} line 1): \#{e.message}\"\n"
        code << "    rescue StandardError => e\n"
        code << "      raise unless __parent_scope__.render_errors\n"
        code << "      __output__ << \"Liquid error (#{name} line 1): \#{LiquidIL.clean_error_message(e.message)}\"\n"
        code << "    ensure\n"
        code << "      __parent_scope__.current_file = __prev_file__\n"
        code << "      __parent_scope__.pop_render_depth\n"
        code << "    end\n"
        code << "  }\n\n"
      end
      code
    end

    def indent_partial_body(body, spaces)
      indent = " " * spaces
      # Replace __scope__ with __partial_scope__ to avoid closure issues
      body = body.gsub("__scope__", "__partial_scope__")
      body.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l}" }.join
    end

    # Generate inline helper lambdas
    def generate_helpers
      <<~RUBY
        # Inline helpers for YJIT optimization
        __output_string__ = ->(value) {
          case value
          when Integer, Float then value.to_s
          when nil then ""
          when true then "true"
          when false then "false"
          when Array then value.map { |i| i.is_a?(String) ? i : __output_string__.call(i) }.join
          else LiquidIL::Utils.output_string(value)
          end
        }

        __is_truthy__ = ->(value) {
          # Drops with to_liquid_value should use that for truthiness
          value = value.to_liquid_value if value.respond_to?(:to_liquid_value)
          case value
          when nil, false then false
          when LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral then false
          else true
          end
        }

        __lookup__ = ->(obj, key) {
          return nil if obj.nil?
          case obj
          when Hash
            key_s = key.to_s
            obj[key_s] || obj[key_s.to_sym] || case key_s
              when "first" then (p = obj.first) ? "\#{p[0]}\#{p[1]}" : nil
              when "size", "length" then obj.length
              end
          when Array
            case key
            when Integer then obj[key]
            else
              case key.to_s
              when "size", "length" then obj.length
              when "first" then obj.first
              when "last" then obj.last
              else obj[key.to_i]
              end
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop then obj[key]
          when LiquidIL::RangeValue
            case key.to_s
            when "first" then obj.first
            when "last" then obj.last
            when "size", "length" then obj.length
            end
          when String
            case key.to_s
            when "size", "length" then obj.length
            when "first" then obj[0]
            when "last" then obj[-1]
            end
          when Integer
            # Ruby integers have .size method that returns byte count
            case key.to_s
            when "size" then obj.size
            end
          else
            obj.respond_to?(:[]) ? obj[key.to_s] : nil
          end
        }

        __call_filter__ = ->(name, input, args, scope, current_file = nil, line = 1) do
          LiquidIL::Filters.apply(name, input, args, scope)
        rescue LiquidIL::FilterError
          # Filter error in non-strict mode - return nil so ASSIGN assigns nil
          nil
        rescue LiquidIL::FilterRuntimeError => e
          # Filter runtime error - return ErrorMarker for inline error display
          location = current_file ? "\#{current_file} line \#{line}" : "line \#{line}"
          LiquidIL::ErrorMarker.new(e.message, location)
        end

        # Compare helper that outputs errors for incomparable types
        # Takes output and current_file parameters for error reporting
        __compare__ = ->(left, right, op, output = nil, current_file = nil) {
          # Convert drops to their liquid values for comparison
          left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
          right = right.to_liquid_value if right.respond_to?(:to_liquid_value)

          # Normalize Ruby Ranges to RangeValue for comparison
          # (Ruby Range's == doesn't know about RangeValue)
          if left.is_a?(Range) && right.is_a?(LiquidIL::RangeValue)
            left = LiquidIL::RangeValue.new(left.begin, left.end)
          elsif left.is_a?(LiquidIL::RangeValue) && right.is_a?(Range)
            right = LiquidIL::RangeValue.new(right.begin, right.end)
          end

          # Handle EmptyLiteral comparisons
          # NOTE: nil does NOT equal empty in Liquid Ruby
          if right.is_a?(LiquidIL::EmptyLiteral)
            is_empty = !left.nil? && (left == "" || left == [] || (left.respond_to?(:empty?) && left.empty?))
            return op == :eq ? is_empty : !is_empty if [:eq, :ne].include?(op)
          end
          # Handle BlankLiteral comparisons
          # blank includes: nil, false, empty string, whitespace-only strings, empty arrays/hashes
          if right.is_a?(LiquidIL::BlankLiteral)
            is_blank = left.nil? || left == false ||
                       (left.is_a?(String) && left.strip.empty?) ||
                       (left.respond_to?(:empty?) && left.empty?)
            return op == :eq ? is_blank : !is_blank if [:eq, :ne].include?(op)
          end
          if left.is_a?(LiquidIL::EmptyLiteral)
            is_empty = !right.nil? && (right == "" || right == [] || (right.respond_to?(:empty?) && right.empty?))
            return op == :eq ? is_empty : !is_empty if [:eq, :ne].include?(op)
          end
          if left.is_a?(LiquidIL::BlankLiteral)
            is_blank = right.nil? || right == false ||
                       (right.is_a?(String) && right.strip.empty?) ||
                       (right.respond_to?(:empty?) && right.empty?)
            return op == :eq ? is_blank : !is_blank if [:eq, :ne].include?(op)
          end

          # For ordered comparisons (<, <=, >, >=), nil makes comparison false
          if [:lt, :le, :gt, :ge].include?(op) && (left.nil? || right.nil?)
            return false
          end

          case op
          when :eq then left == right
          when :ne then left != right
          when :lt, :le, :gt, :ge
            # Ordered comparison - matches VM compare_numeric logic
            # nil, true, false, Array, Hash, Range comparisons are silently false
            return false if left == true || left == false || right == true || right == false
            return false if left.is_a?(Array) || left.is_a?(Hash) || right.is_a?(Array) || right.is_a?(Hash)
            return false if left.is_a?(LiquidIL::RangeValue) || right.is_a?(LiquidIL::RangeValue)

            # Try to convert both sides to numbers
            to_num = ->(v) {
              case v
              when Integer, Float then v
              when String
                if v =~ /\\A-?\\d+\\z/ then v.to_i
                elsif v =~ /\\A-?\\d+\\.\\d+\\z/ then v.to_f
                else nil
                end
              else nil
              end
            }

            left_num = to_num.call(left)
            right_num = to_num.call(right)

            if left_num.nil? || right_num.nil?
              # Incomparable types - output error and return false
              if output
                right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
                location = current_file ? "\#{current_file} line 1" : "line 1"
                output << "Liquid error (\#{location}): comparison of \#{left.class} with \#{right_str} failed"
              end
              return false
            end

            case op
            when :lt then left_num < right_num
            when :le then left_num <= right_num
            when :gt then left_num > right_num
            when :ge then left_num >= right_num
            end
          else false
          end
        }

        __contains__ = ->(left, right) {
          return false if left.nil? || right.nil?
          case left
          when String then left.include?(right.to_s)
          when Array then left.include?(right)
          when Hash then left.key?(right.to_s) || left.key?(right.to_s.to_sym)
          else false
          end
        }

        # Convert value to iterable array for for loops
        __to_iterable__ = ->(value) {
          case value
          when nil, true, false, Integer, Float
            []
          when String
            value.empty? ? [] : [value]
          when LiquidIL::RangeValue
            value.to_a
          when Array
            value
          when Hash
            value.map { |k, v| [k, v] }
          else
            # Try to_a first if available
            if value.respond_to?(:to_a)
              begin
                value.to_a
              rescue
                value.respond_to?(:each) ? value.to_enum.to_a : []
              end
            elsif value.respond_to?(:each)
              value.to_enum.to_a
            else
              []
            end
          end
        }

        # Bracket lookup obj[key] - stricter than property access
        # Ranges as keys return nil, no first/last/size for arrays
        __bracket_lookup__ = ->(obj, key) {
          return nil if obj.nil?
          # Ranges cannot be used as hash keys
          return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)
          # Convert drop keys to their value
          key = key.to_liquid_value if key.respond_to?(:to_liquid_value)
          case obj
          when Hash
            # Try key directly, then string, then symbol
            result = obj[key]
            return result unless result.nil?
            key_str = key.to_s
            result = obj[key_str]
            return result unless result.nil?
            obj[key.to_sym] if key.is_a?(String)
          when Array
            # Only integer keys for bracket notation
            if key.is_a?(Integer)
              obj[key]
            elsif key.to_s =~ /\\A-?\\d+\\z/
              obj[key.to_i]
            else
              nil
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop
            obj[key]
          else
            nil
          end
        }

        # Slice collection for for loops - mimics VM's slice algorithm
        # from = offset, to = from + limit
        # Includes items where from <= index, breaks when to <= index
        __slice_collection__ = ->(collection, from, to) {
          segments = []
          index = 0
          collection.each do |item|
            break if to && to <= index
            segments << item if from <= index
            index += 1
          end
          segments
        }

        # Validate integer for limit/offset (mimics VM's valid_integer?)
        __valid_integer__ = ->(value) {
          return true if value.nil?
          return true if value.is_a?(Integer)
          return true if value.is_a?(Float)
          # Strings starting with optional minus and digit are valid
          return true if value.is_a?(String) && value.match?(/\\A-?\\d/)
          false
        }

      RUBY
    end

    # Generate the template body
    def generate_body
      @pc = 0
      code = String.new

      while @pc < @instructions.length
        result = generate_statement(1)
        break if result.nil?
        code << result
      end

      code
    end

    # Generate a single statement, returns Ruby code string
    def generate_statement(indent)
      return nil if @pc >= @instructions.length

      inst = @instructions[@pc]
      return nil if inst.nil?

      prefix = "  " * indent

      case inst[0]
      when IL::HALT
        @pc += 1
        nil

      when IL::WRITE_RAW
        @pc += 1
        if @uses_interrupts
          "#{prefix}__output__ << #{inst[1].inspect} unless __scope__.has_interrupt?\n"
        else
          "#{prefix}__output__ << #{inst[1].inspect}\n"
        end

      when IL::WRITE_VAR
        @pc += 1
        var_expr = "__scope__.lookup(#{inst[1].inspect})"
        "#{prefix}__output__ << ((__v__ = #{var_expr}).is_a?(String) ? __v__ : __output_string__.call(__v__))\n"

      when IL::WRITE_VAR_PATH
        @pc += 1
        var_expr = generate_var_path_expr(inst[1], inst[2])
        "#{prefix}__output__ << ((__v__ = #{var_expr}).is_a?(String) ? __v__ : __output_string__.call(__v__))\n"

      when IL::FIND_VAR, IL::FIND_VAR_PATH
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
        "#{prefix}__output__ << __scope__.increment(#{var.inspect}).to_s\n"

      when IL::DECREMENT
        @pc += 1
        var = inst[1]
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Use scope's decrement - it handles counter independence and proper lookup integration
        "#{prefix}__output__ << __scope__.decrement(#{var.inspect}).to_s\n"

      when IL::PUSH_SCOPE
        @pc += 1
        "#{prefix}__scope__.push_scope\n"

      when IL::POP_SCOPE
        @pc += 1
        "#{prefix}__scope__.pop_scope\n"

      when IL::PUSH_CAPTURE
        @pc += 1
        "#{prefix}__capture_stack__ << __output__; __output__ = String.new\n"

      when IL::POP_CAPTURE
        @pc += 1
        # POP_CAPTURE pushes captured value onto stack, followed by ASSIGN or IFCHANGED_CHECK
        # Peek ahead to determine what follows
        if @instructions[@pc]&.[](0) == IL::ASSIGN
          var = @instructions[@pc][1]
          @pc += 1
          "#{prefix}__captured__ = __output__; __output__ = __capture_stack__.pop; __scope__.assign(#{var.inspect}, __captured__)\n"
        elsif @instructions[@pc]&.[](0) == IL::IFCHANGED_CHECK
          tag_id = @instructions[@pc][1]
          @pc += 1
          # ifchanged: output captured content only if it differs from previous
          code = String.new
          code << "#{prefix}__captured__ = __output__; __output__ = __capture_stack__.pop\n"
          code << "#{prefix}if __captured__ != __ifchanged_state__[#{tag_id.inspect}]\n"
          code << "#{prefix}  __ifchanged_state__[#{tag_id.inspect}] = __captured__\n"
          code << "#{prefix}  __output__ << __captured__\n"
          code << "#{prefix}end\n"
          code
        else
          # Fallback - just restore output (captured value is lost)
          "#{prefix}__output__ = __capture_stack__.pop\n"
        end

      when IL::CYCLE_STEP
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
            when :var then "__scope__.lookup(#{v[1].inspect})"
            else v.inspect
            end
          else
            v.inspect
          end
        end
        # Skip WRITE_VALUE if it follows (we output directly)
        @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
        # Use __cycle_idx__ to avoid conflict with __idx__ in for loops
        # Handle empty values: cycle with 0 choices outputs nothing (empty string)
        if raw_values.empty?
          "#{prefix}__cycle_state__[#{identity.inspect}] = (__cycle_state__[#{identity.inspect}] || 0) + 1\n"
        else
          "#{prefix}__cycle_idx__ = __cycle_state__[#{identity.inspect}] ||= 0; __output__ << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; __cycle_state__[#{identity.inspect}] = __cycle_idx__ + 1\n"
        end

      when IL::CYCLE_STEP_VAR
        @pc += 1
        var_name = inst[1]
        raw_values = inst[2]
        # Extract actual values from tuples
        values_ruby = raw_values.map do |v|
          if v.is_a?(Array)
            case v[0]
            when :lit then v[1].inspect
            when :var then "__scope__.lookup(#{v[1].inspect})"
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
          "#{prefix}__cycle_key__ = __scope__.lookup(#{var_name.inspect}); __cycle_state__[__cycle_key__] = (__cycle_state__[__cycle_key__] || 0) + 1\n"
        else
          "#{prefix}__cycle_key__ = __scope__.lookup(#{var_name.inspect}); __cycle_idx__ = __cycle_state__[__cycle_key__] ||= 0; __output__ << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; __cycle_state__[__cycle_key__] = __cycle_idx__ + 1\n"
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
            code << "#{prefix}__captured__ = __output__; __output__ = __capture_stack__.pop; __scope__.assign(#{var.inspect}, __captured__)\n"
          else
            # Outside loop: just restore output, discard captured content
            code << "#{prefix}__output__ = __capture_stack__.pop\n"
          end
        end

        if @loop_depth > 0
          if interrupt_type == :break
            # Use throw to exit the current loop - depth-1 because we're inside the loop
            code << "#{prefix}throw(:loop_break_#{@loop_depth - 1})\n"
          else
            code << "#{prefix}next\n"
          end
        else
          # Break/continue outside of loop - push interrupt to scope to stop further output
          code << "#{prefix}__scope__.push_interrupt(#{interrupt_type.inspect})\n"
        end

        code

      when IL::LABEL, IL::POP_INTERRUPT, IL::JUMP_IF_INTERRUPT, IL::POP_FORLOOP,
           IL::FOR_END, IL::FOR_NEXT, IL::JUMP_IF_EMPTY, IL::PUSH_FORLOOP, IL::POP,
           IL::IFCHANGED_CHECK, IL::TABLEROW_NEXT, IL::TABLEROW_END
        @pc += 1
        "" # No-ops in structured code (IFCHANGED_CHECK handled by POP_CAPTURE)

      when IL::LOAD_TEMP
        # Load from temp generates expression - peek ahead to see if it's part of an if
        if peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::RENDER_PARTIAL
        generate_partial_call(inst, @pc, indent, isolated: true)

      when IL::INCLUDE_PARTIAL
        generate_partial_call(inst, @pc, indent, isolated: false)

      else
        generate_expression_statement(indent)
      end
    end

    # Build expression until we hit STORE_TEMP
    # Generate an expression statement (expression followed by WRITE_VALUE or ASSIGN)
    def generate_expression_statement(indent)
      prefix = "  " * indent

      # Clear temp assignments before building expression
      @temp_assignments = nil

      # Build expression from current position
      expr, terminator = build_expression

      return nil if expr.nil?

      # Collect any temp assignments that were generated during expression building
      temp_code = String.new
      if @temp_assignments
        @temp_assignments.each do |slot, temp_expr|
          temp_code << "#{prefix}__temp_#{slot}__ = #{expr_to_ruby(temp_expr)}\n"
        end
        @temp_assignments = nil
      end

      case terminator
      when :write_value
        expr_code = expr_to_ruby(expr)
        # Check for ErrorMarker and convert to string, otherwise use normal output
        if @uses_interrupts
          temp_code + "#{prefix}__output__ << ((__v__ = #{expr_code}).is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__.call(__v__)) unless __scope__.has_interrupt?\n"
        else
          temp_code + "#{prefix}__output__ << ((__v__ = #{expr_code}).is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__.call(__v__))\n"
        end
      when :assign
        var = @instructions[@pc - 1][1]
        # Skip assignment if value is ErrorMarker (already output the error)
        temp_code + "#{prefix}__v__ = #{expr_to_ruby(expr)}; __scope__.assign(#{var.inspect}, __v__) unless __v__.is_a?(LiquidIL::ErrorMarker)\n"
      when :assign_local
        var = @instructions[@pc - 1][1]
        # Skip assignment if value is ErrorMarker (already output the error)
        temp_code + "#{prefix}__v__ = #{expr_to_ruby(expr)}; __scope__.assign_local(#{var.inspect}, __v__) unless __v__.is_a?(LiquidIL::ErrorMarker)\n"
      when :store_temp
        slot = @instructions[@pc][1]
        @pc += 1
        temp_code + "#{prefix}__temp_#{slot}__ = #{expr_to_ruby(expr)}\n"
      when :condition
        # Expression is part of a condition, handled by if_statement
        @pc -= 1 # Back up to let if_statement handle it
        nil
      else
        # Just evaluate expression for side effects (rare)
        temp_code + "#{prefix}#{expr_to_ruby(expr)}\n"
      end
    end

    # Generate a partial call (render or include)
    def generate_partial_call(inst, pc, indent, isolated:)
      @pc += 1
      prefix = "  " * indent
      name = inst[1]
      args = inst[2] || {}
      lambda_name = partial_lambda_name(name)
      tag_type = isolated ? "render" : "include"
      line_num = line_for_pc(pc)

      code = String.new
      code << "#{prefix}# #{tag_type} '#{name}'\n"

      # Handle include being disabled inside render context
      unless isolated
        code << "#{prefix}if __scope__.disable_include\n"
        code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"include usage is not allowed in this context\", file: __current_file__, line: #{line_num}, partial_output: __output__.dup)\n"
        code << "#{prefix}else\n"
        prefix = "  " * (indent + 1)
      end

      # Build argument setup code
      code << "#{prefix}__partial_args__ = {}\n"

      # Handle with/for expressions
      with_expr = args["__with__"]
      for_expr = args["__for__"]
      as_alias = args["__as__"]
      item_var = as_alias || name

      # IMPORTANT: Lookup with_expr value BEFORE processing keyword args!
      # Keyword args can modify the scope (e.g., "include 'font' with multiplier: 1.5"
      # where 'multiplier' exists in outer scope). We need the original value.
      if with_expr && !isolated
        expr = generate_var_lookup(with_expr)
        code << "#{prefix}__with_val__ = #{expr}\n"
      end

      # Regular named arguments
      args.each do |k, v|
        next if k.start_with?("__")
        if v.is_a?(Hash) && v[:__var__]
          var_path = v[:__var__]
          expr = var_path.is_a?(Array) ? generate_var_lookup(var_path[0]) : generate_var_lookup(var_path)
          code << "#{prefix}__partial_args__[#{k.inspect}] = #{expr}\n"
          # For include, also assign to current scope
          unless isolated
            code << "#{prefix}__scope__.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
          end
        else
          code << "#{prefix}__partial_args__[#{k.inspect}] = #{v.inspect}\n"
          unless isolated
            code << "#{prefix}__scope__.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
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
        code << "#{prefix}  __for_coll__.each_with_index do |__item__, __idx__|\n"
        code << "#{prefix}    __partial_args__[#{item_var.inspect}] = __item__\n"
        if isolated
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __for_coll__.length).tap { |f| f.index0 = __idx__ }\n"
        end
        code << "#{prefix}    #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
        code << "#{prefix}  end\n"
        if isolated
          # render iterates over ranges
          code << "#{prefix}elsif __for_coll__.is_a?(LiquidIL::RangeValue) || __for_coll__.is_a?(Range)\n"
          code << "#{prefix}  __items__ = __for_coll__.to_a\n"
          code << "#{prefix}  __items__.each_with_index do |__item__, __idx__|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = __item__\n"
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = __idx__ }\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
          code << "#{prefix}  end\n"
          # Also handle other enumerables for render
          code << "#{prefix}elsif !__for_coll__.is_a?(Hash) && !__for_coll__.is_a?(String) && __for_coll__.respond_to?(:each) && __for_coll__.respond_to?(:to_a)\n"
          code << "#{prefix}  __items__ = __for_coll__.to_a\n"
          code << "#{prefix}  __items__.each_with_index do |__item__, __idx__|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = __item__\n"
          code << "#{prefix}    __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = __idx__ }\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
          code << "#{prefix}  end\n"
        end
        code << "#{prefix}elsif __for_coll__.nil?\n"
        code << "#{prefix}  #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
        code << "#{prefix}else\n"
        code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __for_coll__\n"
        code << "#{prefix}  #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
        code << "#{prefix}end\n"
      elsif with_expr
        # Render with a specific value
        # For isolated (render), we lookup here. For include, we already looked up above.
        if isolated
          expr = generate_var_lookup(with_expr)
          code << "#{prefix}__with_val__ = #{expr}\n"
          code << "#{prefix}__partial_args__[#{item_var.inspect}] = __with_val__ unless __with_val__.nil?\n"
          code << "#{prefix}#{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
        else
          # For include, __with_val__ was already looked up BEFORE keyword args modified scope
          code << "#{prefix}if __with_val__.is_a?(Array)\n"
          code << "#{prefix}  __with_val__.each do |__item__|\n"
          code << "#{prefix}    __partial_args__[#{item_var.inspect}] = __item__\n"
          code << "#{prefix}    #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
          code << "#{prefix}  end\n"
          code << "#{prefix}else\n"
          code << "#{prefix}  __partial_args__[#{item_var.inspect}] = __with_val__\n"
          code << "#{prefix}  #{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
          code << "#{prefix}end\n"
        end
      else
        # Simple render
        code << "#{prefix}#{lambda_name}.call(__partial_args__, __output__, __scope__, #{isolated}, caller_line: #{line_num}, parent_cycle_state: __cycle_state__)\n"
      end

      # Close the include disable check
      unless isolated
        code << "  " * indent << "end\n"
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
        "__scope__.lookup(#{parts[0][0].inspect})"
      else
        first_var = parts[0][0]
        rest_keys = parts[1..].map do |match|
          key = match[0] || match[1] || match[2]
          key.to_s =~ /^\d+$/ ? key.to_i : key.inspect
        end
        result = "__scope__.lookup(#{first_var.inspect})"
        rest_keys.each { |k| result = "__lookup__.call(#{result}, #{k})" }
        result
      end
    end

    # Build an expression tree from IL instructions
    # Returns [Expr, terminator_type]
    def build_expression
      stack = []
      seen_is_truthy = false  # Track if we've passed IS_TRUTHY (marks end of expression)

      while @pc < @instructions.length
        inst = @instructions[@pc]

        case inst[0]
        when IL::CONST_INT
          stack << Expr.new(type: :literal, value: inst[1])
          @pc += 1
        when IL::CONST_FLOAT
          stack << Expr.new(type: :literal, value: inst[1])
          @pc += 1
        when IL::CONST_STRING
          stack << Expr.new(type: :literal, value: inst[1])
          @pc += 1
        when IL::CONST_TRUE
          stack << Expr.new(type: :literal, value: true)
          @pc += 1
        when IL::CONST_FALSE
          stack << Expr.new(type: :literal, value: false)
          @pc += 1
        when IL::CONST_NIL
          stack << Expr.new(type: :literal, value: nil)
          @pc += 1
        when IL::CONST_EMPTY
          stack << Expr.new(type: :empty)
          @pc += 1
        when IL::CONST_BLANK
          stack << Expr.new(type: :blank)
          @pc += 1
        when IL::CONST_RANGE
          stack << Expr.new(type: :range, value: [inst[1], inst[2]])
          @pc += 1
        when IL::NEW_RANGE
          right = stack.pop || Expr.new(type: :literal, value: 0)
          left = stack.pop || Expr.new(type: :literal, value: 0)
          stack << Expr.new(type: :dynamic_range, children: [left, right])
          @pc += 1
        when IL::FIND_VAR
          stack << Expr.new(type: :var, value: inst[1])
          @pc += 1
        when IL::FIND_VAR_PATH
          stack << Expr.new(type: :var_path, value: inst[1], children: inst[2].map { |k| Expr.new(type: :literal, value: k) })
          @pc += 1
        when IL::FIND_VAR_DYNAMIC
          # Indirect variable lookup: pop name from stack, lookup by that name
          name_expr = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :dynamic_var, children: [name_expr])
          @pc += 1
        when IL::LOOKUP_KEY
          key = stack.pop || Expr.new(type: :literal, value: nil)
          obj = stack.pop || Expr.new(type: :literal, value: nil)
          # Bracket access uses :bracket_lookup (stricter than property access)
          stack << Expr.new(type: :bracket_lookup, children: [obj, key])
          @pc += 1
        when IL::LOOKUP_CONST_KEY
          obj = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :lookup, value: inst[1], children: [obj])
          @pc += 1
        when IL::LOOKUP_CONST_PATH
          obj = stack.pop || Expr.new(type: :literal, value: nil)
          current = obj
          inst[1].each do |key|
            current = Expr.new(type: :lookup, value: key, children: [current])
          end
          stack << current
          @pc += 1
        when IL::LOOKUP_COMMAND
          obj = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :command, value: inst[1], children: [obj])
          @pc += 1
        when IL::COMPARE
          right = stack.pop || Expr.new(type: :literal, value: nil)
          left = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :compare, value: inst[1], children: [left, right])
          @pc += 1
        when IL::CONTAINS
          right = stack.pop || Expr.new(type: :literal, value: nil)
          left = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :contains, children: [left, right])
          @pc += 1
        when IL::BOOL_NOT
          operand = stack.pop || Expr.new(type: :literal, value: false)
          stack << Expr.new(type: :not, children: [operand])
          @pc += 1
        when IL::IS_TRUTHY
          # Just marks the value as being used as a boolean, no change needed
          # Also marks that we've completed the expression - next JUMP_IF_* is the condition branch
          seen_is_truthy = true
          @pc += 1
        when IL::STORE_TEMP
          # STORE_TEMP pops from stack. If stack has >1 items (from DUP), store and continue
          if stack.length > 1
            slot = inst[1]
            @pc += 1
            # Store temp and continue - used for DUP + STORE_TEMP + WRITE_VALUE patterns
            # Mark that we need to generate temp assignment as a side effect
            @temp_assignments ||= []
            @temp_assignments << [slot, stack.pop]
          else
            # Single item - this is the terminator case
            # DON'T increment @pc here - generate_expression_statement will read slot from inst
            return [stack.last, :store_temp]
          end
        when IL::LOAD_TEMP
          slot = inst[1]
          stack << Expr.new(type: :temp, value: slot)
          @pc += 1
        when IL::POP
          stack.pop
          @pc += 1
        when IL::DUP
          # Duplicate top of stack
          stack << stack.last if stack.any?
          @pc += 1
        when IL::CASE_COMPARE
          right = stack.pop || Expr.new(type: :literal, value: nil)
          left = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :case_compare, children: [left, right])
          @pc += 1
        when IL::BUILD_HASH
          count = inst[1]
          pairs = stack.pop(count * 2)
          # Build hash from pairs: [key1, val1, key2, val2, ...]
          stack << Expr.new(type: :hash, children: pairs)
          @pc += 1
        when IL::CALL_FILTER
          filter_pc = @pc  # Capture PC for error line tracking
          argc = inst[2] || 0
          args = argc > 0 ? stack.pop(argc) : []
          input = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :filter, value: inst[1], children: [input] + args, pc: filter_pc)
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
            # This is 'and' short-circuit - build the full expression
            # Save current position, parse right operand, then return combined expr
            left = stack.pop || Expr.new(type: :literal, value: false)
            @pc += 1
            # Build right operand expression until we hit JUMP or IS_TRUTHY
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
                # Continue building expression for right operand
                case build_inst[0]
                when IL::CONST_INT then stack << Expr.new(type: :literal, value: build_inst[1]); @pc += 1
                when IL::CONST_FLOAT then stack << Expr.new(type: :literal, value: build_inst[1]); @pc += 1
                when IL::CONST_STRING then stack << Expr.new(type: :literal, value: build_inst[1]); @pc += 1
                when IL::CONST_TRUE then stack << Expr.new(type: :literal, value: true); @pc += 1
                when IL::CONST_FALSE then stack << Expr.new(type: :literal, value: false); @pc += 1
                when IL::CONST_NIL then stack << Expr.new(type: :literal, value: nil); @pc += 1
                when IL::CONST_EMPTY then stack << Expr.new(type: :empty); @pc += 1
                when IL::CONST_BLANK then stack << Expr.new(type: :blank); @pc += 1
                when IL::FIND_VAR then stack << Expr.new(type: :var, value: build_inst[1]); @pc += 1
                when IL::FIND_VAR_PATH then stack << Expr.new(type: :var_path, value: build_inst[1], children: build_inst[2].map { |k| Expr.new(type: :literal, value: k) }); @pc += 1
                when IL::LOAD_TEMP then stack << Expr.new(type: :temp, value: build_inst[1]); @pc += 1
                when IL::LOOKUP_CONST_KEY
                  obj = stack.pop || Expr.new(type: :literal, value: nil)
                  stack << Expr.new(type: :lookup, value: build_inst[1], children: [obj])
                  @pc += 1
                when IL::COMPARE
                  right = stack.pop || Expr.new(type: :literal, value: nil)
                  cmp_left = stack.pop || Expr.new(type: :literal, value: nil)
                  stack << Expr.new(type: :compare, value: build_inst[1], children: [cmp_left, right])
                  @pc += 1
                when IL::CONTAINS
                  right = stack.pop || Expr.new(type: :literal, value: nil)
                  cmp_left = stack.pop || Expr.new(type: :literal, value: nil)
                  stack << Expr.new(type: :contains, children: [cmp_left, right])
                  @pc += 1
                when IL::BOOL_NOT
                  operand = stack.pop || Expr.new(type: :literal, value: false)
                  stack << Expr.new(type: :not, children: [operand])
                  @pc += 1
                when IL::IS_TRUTHY then @pc += 1
                else @pc += 1
                end
              else
                break
              end
            end
            right = stack.pop || Expr.new(type: :literal, value: false)
            stack << Expr.new(type: :and, children: [left, right])
            # Skip IS_TRUTHY if present (the JUMP in right operand skips CONST_FALSE)
            if @instructions[@pc]&.[](0) == IL::IS_TRUTHY
              @pc += 1
            end
          elsif inst[0] == IL::JUMP_IF_TRUE && target_inst&.[](0) == IL::CONST_TRUE && is_short_circuit_pattern
            # This is 'or' short-circuit - collect ALL operands in the chain
            or_operands = [stack.pop || Expr.new(type: :literal, value: false)]
            @pc += 1

            # Keep collecting operands until we hit IS_TRUTHY or exit the OR pattern
            while @pc < @instructions.length
              build_inst = @instructions[@pc]
              break if build_inst.nil?

              case build_inst[0]
              when IL::IS_TRUTHY
                @pc += 1
                break
              when IL::CONST_TRUE
                # Part of the short-circuit success path, skip
                @pc += 1
              when IL::JUMP
                # Either skipping CONST_TRUE or jumping to end
                # Check if target is CONST_TRUE (part of OR success chain)
                jmp_target = build_inst[1]
                if @instructions[jmp_target]&.[](0) == IL::CONST_TRUE || @instructions[jmp_target]&.[](0) == IL::IS_TRUTHY
                  @pc = jmp_target
                else
                  @pc += 1
                end
              when IL::LABEL
                @pc += 1
              when IL::FIND_VAR
                # Build full expression for this OR operand
                # It could be: simple var, var with comparison, or nested AND
                or_operand = build_or_operand(build_inst[1])
                if or_operand
                  or_operands << or_operand
                else
                  break
                end
              when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_FALSE, IL::CONST_NIL
                # Literal as final operand
                case build_inst[0]
                when IL::CONST_INT then or_operands << Expr.new(type: :literal, value: build_inst[1])
                when IL::CONST_FLOAT then or_operands << Expr.new(type: :literal, value: build_inst[1])
                when IL::CONST_STRING then or_operands << Expr.new(type: :literal, value: build_inst[1])
                when IL::CONST_FALSE then or_operands << Expr.new(type: :literal, value: false)
                when IL::CONST_NIL then or_operands << Expr.new(type: :literal, value: nil)
                end
                @pc += 1
                if @instructions[@pc]&.[](0) == IL::JUMP
                  @pc = @instructions[@pc][1]
                end
                break
              else
                # Unknown instruction - stop collecting
                break
              end
            end

            # Build left-associative OR tree from collected operands: (((a or b) or c) or d)
            result = or_operands.first
            or_operands[1..].each do |operand|
              result = Expr.new(type: :or, children: [result, operand])
            end
            stack << result
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

    # Build a single value expression (for limit/offset which are simple values)
    # This reads one logical value, which may be a single constant or a complete expression
    def build_single_value_expression
      inst = @instructions[@pc]
      return nil if inst.nil?

      case inst[0]
      when IL::CONST_INT
        # Check if this is the start of a range (CONST_INT, CONST_INT|CONST_FLOAT, NEW_RANGE)
        next_inst = @instructions[@pc + 1]
        next_next = @instructions[@pc + 2]
        if (next_inst&.[](0) == IL::CONST_INT || next_inst&.[](0) == IL::CONST_FLOAT) && next_next&.[](0) == IL::NEW_RANGE
          # This is a range - consume all three instructions
          start_val = inst[1]
          end_val = next_inst[1]
          @pc += 3
          return Expr.new(type: :dynamic_range, children: [
            Expr.new(type: :literal, value: start_val),
            Expr.new(type: :literal, value: end_val)
          ])
        end
        @pc += 1
        Expr.new(type: :literal, value: inst[1])
      when IL::CONST_FLOAT
        @pc += 1
        Expr.new(type: :literal, value: inst[1])
      when IL::CONST_STRING
        @pc += 1
        Expr.new(type: :literal, value: inst[1])
      when IL::CONST_RANGE
        @pc += 1
        Expr.new(type: :range, value: [inst[1], inst[2]])
      when IL::FIND_VAR
        # Check if followed by CONST_INT, NEW_RANGE (dynamic range like x..5)
        next_inst = @instructions[@pc + 1]
        next_next = @instructions[@pc + 2]
        if next_inst&.[](0) == IL::CONST_INT && next_next&.[](0) == IL::NEW_RANGE
          start_expr = Expr.new(type: :var, value: inst[1])
          end_val = next_inst[1]
          @pc += 3
          return Expr.new(type: :dynamic_range, children: [
            start_expr,
            Expr.new(type: :literal, value: end_val)
          ])
        end
        # Check if followed by FIND_VAR, NEW_RANGE (dynamic range like x..y)
        if next_inst&.[](0) == IL::FIND_VAR && next_next&.[](0) == IL::NEW_RANGE
          start_expr = Expr.new(type: :var, value: inst[1])
          end_expr = Expr.new(type: :var, value: next_inst[1])
          @pc += 3
          return Expr.new(type: :dynamic_range, children: [start_expr, end_expr])
        end
        # Check if followed by LOOKUP_CONST_KEY (property access like obj.prop)
        if next_inst&.[](0) == IL::LOOKUP_CONST_KEY
          result = Expr.new(type: :var, value: inst[1])
          @pc += 1
          # Consume all LOOKUP_CONST_KEY chain (for paths like a.b.c)
          while @instructions[@pc]&.[](0) == IL::LOOKUP_CONST_KEY
            key = @instructions[@pc][1]
            result = Expr.new(type: :lookup, value: key, children: [result])
            @pc += 1
          end
          return result
        end
        # Check if followed by CONST_STRING/CONST_INT, LOOKUP_KEY (bracket access like obj["key"])
        if (next_inst&.[](0) == IL::CONST_STRING || next_inst&.[](0) == IL::CONST_INT) && next_next&.[](0) == IL::LOOKUP_KEY
          obj_expr = Expr.new(type: :var, value: inst[1])
          key_expr = Expr.new(type: :literal, value: next_inst[1])
          @pc += 3  # Consume FIND_VAR, CONST_*, LOOKUP_KEY
          return Expr.new(type: :bracket_lookup, children: [obj_expr, key_expr])
        end
        # Simple variable lookup - just consume this one instruction
        # Don't use full build_expression which would consume subsequent FIND_VARs
        @pc += 1
        Expr.new(type: :var, value: inst[1])
      when IL::FIND_VAR_PATH
        @pc += 1
        Expr.new(type: :var_path, value: inst[1], children: inst[2].map { |k| Expr.new(type: :literal, value: k) })
      when IL::LOAD_TEMP
        @pc += 1
        Expr.new(type: :temp, value: inst[1])
      else
        # For complex expressions, use full builder
        expr, _ = build_expression
        expr
      end
    end

    # Build a complete OR operand expression starting from a FIND_VAR
    # Handles: simple var, var with comparison (var == val), or nested AND
    # Returns the expression or nil if we should stop collecting
    def build_or_operand(var_name)
      # Start with the variable
      expr = Expr.new(type: :var, value: var_name)
      @pc += 1

      # Look ahead to see what follows
      next_inst = @instructions[@pc]
      return nil if next_inst.nil?

      case next_inst[0]
      when IL::JUMP_IF_TRUE
        # Check if this is another OR operand (JUMP_IF_TRUE → CONST_TRUE)
        jit_target = next_inst[1]
        jit_actual = jit_target
        while @instructions[jit_actual]&.[](0) == IL::LABEL
          jit_actual += 1
        end
        if @instructions[jit_actual]&.[](0) == IL::CONST_TRUE
          # Simple variable OR operand
          @pc += 1 # Skip JUMP_IF_TRUE
          expr
        else
          # Not part of OR chain
          nil
        end

      when IL::JUMP_IF_FALSE
        # This could be a nested AND expression
        jif_target = next_inst[1]
        jif_actual = jif_target
        while @instructions[jif_actual]&.[](0) == IL::LABEL
          jif_actual += 1
        end
        if @instructions[jif_actual]&.[](0) == IL::CONST_FALSE
          # Nested AND - build it
          @pc += 1 # Skip JUMP_IF_FALSE
          and_operands = [expr]
          while @pc < jif_target
            and_inst = @instructions[@pc]
            break if and_inst.nil? || and_inst[0] == IL::JUMP
            case and_inst[0]
            when IL::FIND_VAR
              and_operands << Expr.new(type: :var, value: and_inst[1])
              @pc += 1
              if @instructions[@pc]&.[](0) == IL::JUMP_IF_FALSE
                @pc += 1
              end
            when IL::CONST_TRUE
              and_operands << Expr.new(type: :literal, value: true)
              @pc += 1
            when IL::CONST_FALSE
              and_operands << Expr.new(type: :literal, value: false)
              @pc += 1
            when IL::LABEL
              @pc += 1
            else
              @pc += 1
            end
          end
          # Skip JUMP that skips CONST_FALSE
          if @instructions[@pc]&.[](0) == IL::JUMP
            @pc = @instructions[@pc][1]
          end
          # Build AND tree
          and_result = and_operands.first
          and_operands[1..].each do |op|
            and_result = Expr.new(type: :and, children: [and_result, op])
          end
          # Check for trailing CONST_TRUE
          if @instructions[@pc]&.[](0) == IL::CONST_TRUE
            @pc += 1
          end
          and_result
        else
          nil
        end

      when IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_NIL
        # Variable followed by constant - likely a comparison (e.g., b == false)
        # Build the expression: FIND_VAR, CONST_*, COMPARE
        # We already have the var on expr, now get the constant
        const_expr = case next_inst[0]
        when IL::CONST_TRUE then Expr.new(type: :literal, value: true)
        when IL::CONST_FALSE then Expr.new(type: :literal, value: false)
        when IL::CONST_INT then Expr.new(type: :literal, value: next_inst[1])
        when IL::CONST_FLOAT then Expr.new(type: :literal, value: next_inst[1])
        when IL::CONST_STRING then Expr.new(type: :literal, value: next_inst[1])
        when IL::CONST_NIL then Expr.new(type: :literal, value: nil)
        end
        @pc += 1

        # Check for COMPARE
        compare_inst = @instructions[@pc]
        if compare_inst&.[](0) == IL::COMPARE
          expr = Expr.new(type: :compare, value: compare_inst[1], children: [expr, const_expr])
          @pc += 1
        elsif compare_inst&.[](0) == IL::CONTAINS
          expr = Expr.new(type: :contains, children: [expr, const_expr])
          @pc += 1
        end
        # Skip JUMP that goes to IS_TRUTHY/CONST_TRUE
        if @instructions[@pc]&.[](0) == IL::JUMP
          @pc = @instructions[@pc][1]
        end
        expr

      when IL::JUMP
        # Final operand with trailing JUMP
        @pc = next_inst[1]
        expr

      else
        # Just the variable - final operand
        expr
      end
    end

    # Convert expression tree to Ruby code
    def expr_to_ruby(expr)
      return "nil" if expr.nil?

      case expr.type
      when :literal
        # Handle special Float values (NaN, Infinity)
        if expr.value.is_a?(Float)
          if expr.value.nan?
            "Float::NAN"
          elsif expr.value.infinite? == 1
            "Float::INFINITY"
          elsif expr.value.infinite? == -1
            "-Float::INFINITY"
          else
            expr.value.inspect
          end
        else
          expr.value.inspect
        end
      when :var
        "__scope__.lookup(#{expr.value.inspect})"
      when :var_path
        generate_var_path_expr(expr.value, expr.children.map { |c| c.value })
      when :empty
        "LiquidIL::EmptyLiteral.instance"
      when :blank
        "LiquidIL::BlankLiteral.instance"
      when :range
        "LiquidIL::RangeValue.new(#{expr.value[0]}, #{expr.value[1]})"
      when :dynamic_range
        "LiquidIL::RangeValue.new(#{expr_to_ruby(expr.children[0])}, #{expr_to_ruby(expr.children[1])})"
      when :lookup
        obj = expr_to_ruby(expr.children[0])
        if expr.value # const key
          "__lookup__.call(#{obj}, #{expr.value.inspect})"
        else # dynamic key
          "__lookup__.call(#{obj}, #{expr_to_ruby(expr.children[1])})"
        end
      when :bracket_lookup
        # Bracket access obj[key] - stricter semantics than property access
        obj = expr_to_ruby(expr.children[0])
        key = expr_to_ruby(expr.children[1])
        "__bracket_lookup__.call(#{obj}, #{key})"
      when :command
        obj = expr_to_ruby(expr.children[0])
        case expr.value
        when "size", "length"
          "((__o__ = #{obj}).respond_to?(:length) ? __o__.length : nil)"
        when "first"
          "((__o__ = #{obj}).respond_to?(:first) ? __o__.first : nil)"
        when "last"
          "((__o__ = #{obj}).respond_to?(:last) ? __o__.last : nil)"
        else
          "__lookup__.call(#{obj}, #{expr.value.inspect})"
        end
      when :compare
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "__compare__.call(#{left}, #{right}, #{expr.value.inspect}, __output__, __current_file__)"
      when :contains
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "__contains__.call(#{left}, #{right})"
      when :not
        "!__is_truthy__.call(#{expr_to_ruby(expr.children[0])})"
      when :hash
        # Build hash from pairs: children = [key1, val1, key2, val2, ...]
        pairs = []
        i = 0
        while i < expr.children.length
          key = expr_to_ruby(expr.children[i])
          val = expr_to_ruby(expr.children[i + 1])
          pairs << "#{key} => #{val}"
          i += 2
        end
        "{#{pairs.join(', ')}}"
      when :filter
        input = expr_to_ruby(expr.children[0])
        args = expr.children[1..].map { |a| expr_to_ruby(a) }
        # Compute line number from filter's PC for error reporting
        filter_line = expr.pc ? line_for_pc(expr.pc) : 1
        if args.empty?
          "__call_filter__.call(#{expr.value.inspect}, #{input}, [], __scope__, __current_file__, #{filter_line})"
        else
          "__call_filter__.call(#{expr.value.inspect}, #{input}, [#{args.join(', ')}], __scope__, __current_file__, #{filter_line})"
        end
      when :case_compare
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "LiquidIL::Utils.case_equal?(#{right}, #{left})"
      when :temp
        "__temp_#{expr.value}__"
      when :and
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "(__is_truthy__.call(#{left}) && __is_truthy__.call(#{right}))"
      when :or
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "(__is_truthy__.call(#{left}) || __is_truthy__.call(#{right}))"
      when :dynamic_var
        # Indirect variable lookup: {{ [name_var] }} looks up variable by name in name_var
        name_code = expr_to_ruby(expr.children[0])
        "__scope__.lookup((#{name_code}).to_s)"
      else
        "nil # unknown expr type: #{expr.type}"
      end
    end

    # Generate variable path access (a.b.c)
    def generate_var_path_expr(var, path)
      result = "__scope__.lookup(#{var.inspect})"
      path.each do |key|
        result = "__lookup__.call(#{result}, #{key.inspect})"
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
          # After JUMP_IF_EMPTY, look for FOR_INIT (may have hoisted expressions in between)
          j = i + 1
          while j < @instructions.length
            next_inst = @instructions[j]
            break if next_inst.nil?
            case next_inst[0]
            when IL::FOR_INIT
              return true
            when IL::FIND_VAR, IL::CONST_INT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE,
                 IL::STORE_TEMP, IL::LOAD_TEMP
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
        when IL::FOR_INIT, IL::HALT, IL::WRITE_VALUE, IL::ASSIGN, IL::ASSIGN_LOCAL, IL::STORE_TEMP
          # These terminate the expression without being an if condition
          return false
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
      prefix = "  " * indent

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
      generate_for_loop_body_with_expr(Expr.new(type: :var, value: collection_var || "items"), end_pc, indent)
    end

    # Generate for loop body with expression
    def generate_for_loop_body_with_expr(coll_expr, end_pc, indent)
      prefix = "  " * indent
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

      # Handle any pre-loop setup (optimizer may hoist expressions before FOR_INIT)
      # But ONLY look for FIND_VAR + STORE_TEMP patterns, not bare constants
      # (bare constants before FOR_INIT are offset/limit values)
      while @pc < @instructions.length && @instructions[@pc][0] != IL::FOR_INIT
        inst = @instructions[@pc]
        case inst[0]
        when IL::FIND_VAR
          # Check if this is a hoisted variable followed by STORE_TEMP
          next_inst = @instructions[@pc + 1]
          if next_inst && next_inst[0] == IL::STORE_TEMP
            # This is a hoisted FIND_VAR -> STORE_TEMP pattern
            var_name = inst[1]
            slot = next_inst[1]
            @pc += 2
            pre_loop_code << "#{prefix}__temp_#{slot}__ = __scope__.lookup(#{var_name.inspect})\n"
          else
            # Not followed by STORE_TEMP, this is an offset/limit expression
            break
          end
        when IL::STORE_TEMP
          @pc += 1 # Skip orphaned STORE_TEMP
        when IL::CONST_INT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_FLOAT, IL::CONST_NIL
          # Bare constants before FOR_INIT are offset/limit values, stop here
          break
        else
          break
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

      # Track loop depth for nested loops - increment BEFORE parsing body
      depth = @loop_depth
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
      coll_ruby = expr_to_ruby(coll_expr)

      # Use depth-indexed variables for forloop and collection
      forloop_var = "__forloop_#{depth}__"
      coll_var = "__coll_#{depth}__"
      item_var_internal = "__item_#{depth}__"
      idx_var = "__idx_#{depth}__"

      # Get parent forloop reference (if nested)
      # Always check scope for existing forloop - this handles:
      # - parentloop access in includes (depth 0 with outer loop in scope)
      # - for loops inside tablerows (depth > 0 but no __forloop_{depth-1}__ exists)
      parent_forloop = "__scope__.lookup('forloop')"

      # Wrap validation and loop in begin/rescue for inline error handling
      needs_error_handling = has_offset || has_limit
      code << "#{prefix}# for #{item_var}\n"
      code << "#{prefix}begin\n" if needs_error_handling
      inner_prefix = needs_error_handling ? "#{prefix}  " : prefix

      # Store original collection to check if it's a string (strings ignore offset/limit)
      code << "#{inner_prefix}__orig_coll_#{depth}__ = #{coll_ruby}\n"
      code << "#{inner_prefix}__is_string_#{depth}__ = __orig_coll_#{depth}__.is_a?(String)\n"
      # Check if collection is nil/false (skip validation for nil/false)
      code << "#{inner_prefix}__is_nil_#{depth}__ = __orig_coll_#{depth}__.nil? || __orig_coll_#{depth}__ == false\n"
      code << "#{inner_prefix}#{coll_var} = __to_iterable__.call(__orig_coll_#{depth}__)\n"

      # Calculate starting offset for offset:continue or explicit offset
      offset_var = "__start_offset_#{depth}__"
      if offset_continue
        # offset:continue uses stored offset from previous loop with same name
        code << "#{inner_prefix}#{offset_var} = __scope__.for_offset(#{loop_name.inspect})\n"
      elsif offset_expr
        offset_ruby = expr_to_ruby(offset_expr)
        # Validate offset is a valid integer (unless collection is nil/false)
        if has_offset
          code << "#{inner_prefix}__offset_val_#{depth}__ = #{offset_ruby}\n"
          code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: __current_file__, line: 1) unless __is_nil_#{depth}__ || __valid_integer__.call(__offset_val_#{depth}__)\n"
          code << "#{inner_prefix}#{offset_var} = __offset_val_#{depth}__.to_i\n"
        else
          code << "#{inner_prefix}#{offset_var} = (#{offset_ruby}).to_i\n"
        end
      else
        code << "#{inner_prefix}#{offset_var} = 0\n"
      end

      # Slice collection using Liquid's algorithm (to = from + limit)
      # Strings ignore offset and limit
      if limit_expr
        limit_ruby = expr_to_ruby(limit_expr)
        # Validate limit is a valid integer (unless collection is nil/false)
        if has_limit
          code << "#{inner_prefix}__limit_val_#{depth}__ = #{limit_ruby}\n"
          code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: __current_file__, line: 1) unless __is_nil_#{depth}__ || __valid_integer__.call(__limit_val_#{depth}__)\n"
          code << "#{inner_prefix}__to_#{depth}__ = #{offset_var} + __limit_val_#{depth}__.to_i\n"
        else
          code << "#{inner_prefix}__to_#{depth}__ = #{offset_var} + (#{limit_ruby}).to_i\n"
        end
        code << "#{inner_prefix}#{coll_var} = __slice_collection__.call(#{coll_var}, #{offset_var}, __to_#{depth}__) unless __is_string_#{depth}__\n"
      else
        # No limit - just apply offset using slice (from <= index)
        code << "#{inner_prefix}#{coll_var} = __slice_collection__.call(#{coll_var}, #{offset_var}, nil) unless __is_string_#{depth}__\n"
      end

      code << "#{inner_prefix}#{coll_var} = #{coll_var}.reverse\n" if reversed
      code << "#{inner_prefix}if !#{coll_var}.empty?\n"
      code << "#{inner_prefix}  __scope__.push_scope\n"
      code << "#{inner_prefix}  #{forloop_var} = LiquidIL::ForloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{parent_forloop})\n"
      # Wrap with catch for break support (throw/catch works across block boundaries)
      code << "#{inner_prefix}  catch(:loop_break_#{depth}) do\n"
      code << "#{inner_prefix}    #{coll_var}.each_with_index do |#{item_var_internal}, #{idx_var}|\n"
      code << "#{inner_prefix}      #{forloop_var}.index0 = #{idx_var}\n"
      code << "#{inner_prefix}      __scope__.assign_local('forloop', #{forloop_var})\n"
      code << "#{inner_prefix}      __scope__.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
      # Adjust body_code indentation if we have error handling
      if needs_error_handling
        body_code = body_code.gsub(/^/, "  ")
      end
      code << body_code
      code << "#{inner_prefix}    end\n"
      code << "#{inner_prefix}  end\n"
      code << "#{inner_prefix}  # Update forloop.index0 to final count (for escaped references)\n"
      code << "#{inner_prefix}  #{forloop_var}.index0 = #{coll_var}.length\n"
      code << "#{inner_prefix}  # Update offset:continue position for next loop with same name\n"
      code << "#{inner_prefix}  __scope__.set_for_offset(#{loop_name.inspect}, #{offset_var} + #{coll_var}.length)\n"
      code << "#{inner_prefix}  __scope__.pop_scope\n"

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
        code << "#{prefix}rescue LiquidIL::RuntimeError => __e_#{depth}__\n"
        code << "#{prefix}  raise unless __scope__.render_errors\n"
        code << "#{prefix}  __loc_#{depth}__ = __e_#{depth}__.file ? \"\#{__e_#{depth}__.file} line \#{__e_#{depth}__.line}\" : \"line \#{__e_#{depth}__.line}\"\n"
        code << "#{prefix}  __output__ << \"Liquid error (\#{__loc_#{depth}__}): \#{__e_#{depth}__.message}\"\n"
        code << "#{prefix}end\n"
      end

      @loop_depth -= 1
      code
    end

    # Generate a tablerow loop (called when FIND_VAR starts a tablerow sequence)
    def generate_tablerow(indent)
      prefix = "  " * indent

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
            pre_loop_code << "#{"  " * indent}__temp_#{slot}__ = __scope__.lookup(#{var_name.inspect})\n"
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
      prefix = "  " * indent

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
        coll_expr = Expr.new(type: :var, value: "items")
      end

      # Track loop depth for nested loops
      depth = @loop_depth
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
      coll_ruby = expr_to_ruby(coll_expr)

      code << "#{prefix}# tablerow #{item_var}\n"
      code << "#{prefix}__orig_tablerow_coll_#{depth}__ = #{coll_ruby}\n"
      code << "#{prefix}__is_string_#{depth}__ = __orig_tablerow_coll_#{depth}__.is_a?(String)\n"
      code << "#{prefix}__is_nil_#{depth}__ = __orig_tablerow_coll_#{depth}__.nil? || __orig_tablerow_coll_#{depth}__ == false\n"
      code << "#{prefix}#{coll_var} = __to_iterable__.call(__orig_tablerow_coll_#{depth}__)\n"

      # Handle cols parameter
      case cols
      when :dynamic
        if cols_expr
          code << "#{prefix}__cols_val_#{depth}__ = #{expr_to_ruby(cols_expr)}\n"
          code << "#{prefix}if __cols_val_#{depth}__.nil?\n"
          code << "#{prefix}  #{cols_var} = #{coll_var}.length\n"
          code << "#{prefix}  __cols_explicit_nil_#{depth}__ = true\n"
          code << "#{prefix}elsif !__is_nil_#{depth}__ && !__valid_integer__.call(__cols_val_#{depth}__)\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: __current_file__, line: 1)\n"
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
          offset_ruby = expr_to_ruby(offset_expr)
          code << "#{prefix}__offset_val_#{depth}__ = #{offset_ruby}\n"
          code << "#{prefix}unless __is_nil_#{depth}__\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: __current_file__, line: 1) unless __valid_integer__.call(__offset_val_#{depth}__)\n"
          code << "#{prefix}  __offset_#{depth}__ = __offset_val_#{depth}__.nil? ? 0 : __offset_val_#{depth}__.to_i\n"
          code << "#{prefix}  __offset_#{depth}__ = [__offset_#{depth}__, 0].max\n"
          code << "#{prefix}  #{coll_var} = #{coll_var}.drop(__offset_#{depth}__) unless __is_string_#{depth}__\n"
          code << "#{prefix}end\n"
        end
      end

      # Handle limit if present (validate and apply) - for strings, limit is ignored
      # nil limit means take 0 items for tablerow (different from for loop)
      # Skip all processing if collection is nil/false (no output will be generated anyway)
      if has_limit
        if limit_expr
          limit_ruby = expr_to_ruby(limit_expr)
          code << "#{prefix}__limit_val_#{depth}__ = #{limit_ruby}\n"
          code << "#{prefix}unless __is_nil_#{depth}__\n"
          code << "#{prefix}  raise LiquidIL::RuntimeError.new(\"invalid integer\", file: __current_file__, line: 1) unless __valid_integer__.call(__limit_val_#{depth}__)\n"
          code << "#{prefix}  __limit_#{depth}__ = __limit_val_#{depth}__.nil? ? 0 : __limit_val_#{depth}__.to_i\n"
          code << "#{prefix}  __limit_#{depth}__ = 0 if __limit_#{depth}__ < 0\n"
          code << "#{prefix}  #{coll_var} = #{coll_var}.take(__limit_#{depth}__) unless __is_string_#{depth}__\n"
          code << "#{prefix}end\n"
        end
      end

      # Ensure cols is at least 1 to avoid division by zero
      code << "#{prefix}#{cols_var} = [#{cols_var}, 1].max\n"

      code << "#{prefix}__scope__.push_scope\n"
      code << "#{prefix}#{tablerowloop_var} = LiquidIL::TablerowloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{cols_var}, nil, __cols_explicit_nil_#{depth}__)\n"

      # Wrap with catch for break support
      code << "#{prefix}catch(:loop_break_#{depth}) do\n"

      # Output opening row tag for empty collections
      code << "#{prefix}  if #{coll_var}.empty? && !__is_nil_#{depth}__\n"
      code << "#{prefix}    __output__ << \"<tr class=\\\"row1\\\">\\n\"\n"
      code << "#{prefix}    __output__ << \"</tr>\\n\"\n"
      code << "#{prefix}  end\n"

      code << "#{prefix}  #{coll_var}.each_with_index do |#{item_var_internal}, #{idx_var}|\n"
      code << "#{prefix}    #{tablerowloop_var}.index0 = #{idx_var}\n"
      code << "#{prefix}    __scope__.assign_local('tablerowloop', #{tablerowloop_var})\n"
      code << "#{prefix}    __scope__.assign_local(#{item_var.inspect}, #{item_var_internal})\n"

      # Output HTML tags before body content
      code << "#{prefix}    # Close previous cell/row if not first iteration\n"
      code << "#{prefix}    if #{idx_var} > 0\n"
      code << "#{prefix}      __output__ << \"</td>\"\n"
      code << "#{prefix}      if (#{idx_var} % #{cols_var}) == 0\n"
      code << "#{prefix}        __output__ << \"</tr>\\n\"\n"
      code << "#{prefix}      end\n"
      code << "#{prefix}    end\n"

      code << "#{prefix}    # Open new row if at start of row\n"
      code << "#{prefix}    if (#{idx_var} % #{cols_var}) == 0\n"
      code << "#{prefix}      __row__ = (#{idx_var} / #{cols_var}) + 1\n"
      code << "#{prefix}      if __row__ == 1\n"
      code << "#{prefix}        __output__ << \"<tr class=\\\"row\#{__row__}\\\">\\n\"\n"
      code << "#{prefix}      else\n"
      code << "#{prefix}        __output__ << \"<tr class=\\\"row\#{__row__}\\\">\"\n"
      code << "#{prefix}      end\n"
      code << "#{prefix}    end\n"
      code << "#{prefix}    __col__ = (#{idx_var} % #{cols_var}) + 1\n"
      code << "#{prefix}    __output__ << \"<td class=\\\"col\#{__col__}\\\">\"\n"

      # Body content
      code << body_code

      code << "#{prefix}  end\n"  # end each_with_index
      code << "#{prefix}end\n"    # end catch

      # Close final tags
      code << "#{prefix}if !#{coll_var}.empty?\n"
      code << "#{prefix}  __output__ << \"</td>\"\n"
      code << "#{prefix}  __output__ << \"</tr>\\n\"\n"
      code << "#{prefix}end\n"
      code << "#{prefix}__scope__.pop_scope\n"

      @loop_depth -= 1
      code
    end

    # Generate an if statement
    def generate_if_statement(indent)
      prefix = "  " * indent

      # Build condition expression
      cond_expr, _ = build_expression

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
      code = String.new
      cond_ruby = cond_expr ? expr_to_ruby(cond_expr) : "nil"

      if jump_type == IL::JUMP_IF_FALSE
        code << "#{prefix}if __is_truthy__.call(#{cond_ruby})\n"
      else
        code << "#{prefix}unless __is_truthy__.call(#{cond_ruby})\n"
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
      prefix = "  " * indent
      conditions = [first_cond]

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
          # No more conditions, this is the "else" jump
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
      cond_parts = conditions.map { |c| expr_to_ruby(c) }
      combined_cond = cond_parts.map { |c| "__is_truthy__.call(#{c})" }.join(" || ")

      code = String.new
      code << "#{prefix}if #{combined_cond}\n"

      # Set the success flag to prevent else branch
      code << "#{prefix}  __temp_#{success_slot}__ = true\n" if success_slot

      # Parse success body until we hit LOAD_TEMP (checking matched flag) or end
      while @pc < @instructions.length
        inst = @instructions[@pc]
        break if inst.nil?

        case inst[0]
        when IL::LOAD_TEMP
          # This is checking the matched flag for else branch - done with body
          break
        when IL::HALT
          break
        else
          result = generate_statement(indent + 1)
          break if result.nil?
          code << result
        end
      end

      code << "#{prefix}end\n"
      code
    end

    # Evaluate generated Ruby code
    # Use TOPLEVEL_BINDING to avoid constant resolution issues in class context
    def eval_ruby(source)
      eval(source, TOPLEVEL_BINDING, "(liquid_il_structured)")
    rescue SyntaxError => e
      # puts "Syntax error: #{e.message}"
      # puts source.lines.each_with_index.map { |l, i| "#{i+1}: #{l}" }.join
      nil
    end
  end

  # StructuredCompiledTemplate wraps a compiled proc for execution
  class StructuredCompiledTemplate
    attr_reader :source, :instructions, :spans, :compiled_source

    def initialize(source, instructions, spans, context, compiled_result)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
    end

    def render(assigns = {}, render_errors: true, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = Scope.new(assigns, registers: @context&.registers&.dup || {}, strict_errors: @context&.strict_errors || false)
      scope.file_system = @context&.file_system
      scope.render_errors = render_errors

      @compiled_proc.call(scope, @spans, @source)
    rescue LiquidIL::RuntimeError => e
      raise unless render_errors
      output = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output + "Liquid error (#{location}): #{e.message}"
    rescue StandardError => e
      raise unless render_errors
      location = scope&.current_file ? "#{scope.current_file} line 1" : "line 1"
      "Liquid error (#{location}): #{LiquidIL.clean_error_message(e.message)}"
    end
  end

  class Compiler
    # Structured Ruby compiler entry point (YJIT-friendly)
    module Structured
      def self.compile(template_or_source, context: nil, **options)
        if template_or_source.is_a?(LiquidIL::Template)
          template = template_or_source
          source = template.source
          context ||= template.instance_variable_get(:@context)
        else
          source = template_or_source
        end

        # Always recompile with optimization for cleanest IL
        compiler = Compiler.new(source, **options.merge(optimize: true))
        result = compiler.compile
        instructions = result[:instructions]
        spans = result[:spans]

        structured_compiler = StructuredCompiler.new(
          instructions,
          spans: spans,
          template_source: source,
          context: context
        )
        compiled_result = structured_compiler.compile

        StructuredCompiledTemplate.new(source, instructions, spans, context, compiled_result)
      end
    end
  end
end
