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
    Expr = Struct.new(:type, :value, :children, keyword_init: true) do
      def initialize(type:, value: nil, children: [])
        super
      end
    end

    # Comparison operator mapping
    COMPARE_OPS = { eq: "==", ne: "!=", lt: "<", le: "<=", gt: ">", ge: ">=" }.freeze

    def initialize(instructions, spans: nil, template_source: nil, context: nil)
      @instructions = instructions
      @spans = spans || []
      @template_source = template_source
      @context = context
      @loop_depth = 0 # Track nested loop depth for parentloop support
    end

    def compile
      return fallback_result unless can_compile?

      code = generate_ruby
      compiled_proc = eval_ruby(code)
      return fallback_result unless compiled_proc

      CompilationResult.new(
        proc: compiled_proc,
        source: code,
        can_compile: true
      )
    rescue StandardError => e
      # puts "Compilation error: #{e.message}"
      # puts e.backtrace.first(5).join("\n")
      fallback_result
    end

    def fallback_result
      CompilationResult.new(proc: nil, source: nil, can_compile: false)
    end

    private

    # Check if we can compile this template
    def can_compile?
      @instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          return false # Partials not yet supported
        when IL::TABLEROW_INIT, IL::TABLEROW_NEXT, IL::TABLEROW_END
          return false # Tablerow not yet supported
        when IL::PUSH_INTERRUPT
          return false # Break/continue not yet supported
        end
      end
      true
    end

    # Generate Ruby code from IL
    def generate_ruby
      code = String.new
      code << "# frozen_string_literal: true\n"
      code << "proc do |__scope__, __spans__, __template_source__|\n"
      code << generate_helpers
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
          else
            obj.respond_to?(:[]) ? obj[key.to_s] : nil
          end
        }

        __call_filter__ = ->(name, input, args, scope) {
          LiquidIL::Filters.apply(name, input, args, scope)
        }

        __compare__ = ->(left, right, op) {
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

          case op
          when :eq then left == right
          when :ne then left != right
          when :lt then (left <=> right) == -1 rescue false
          when :le then (cmp = left <=> right) && cmp <= 0 rescue false
          when :gt then (left <=> right) == 1 rescue false
          when :ge then (cmp = left <=> right) && cmp >= 0 rescue false
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
        "#{prefix}__output__ << #{inst[1].inspect}\n"

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
        elsif peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
           IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK
        if peek_for_loop?
          generate_for_loop(indent)
        elsif peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

      when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE
        generate_if_statement(indent)

      when IL::FOR_INIT
        generate_for_loop_body(nil, nil, indent)

      when IL::JUMP
        target = inst[1]
        @pc = target
        generate_statement(indent)

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
        "#{prefix}__cycle_idx__ = __cycle_state__[#{identity.inspect}] ||= 0; __output__ << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; __cycle_state__[#{identity.inspect}] = __cycle_idx__ + 1\n"

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
        "#{prefix}__cycle_key__ = __scope__.lookup(#{var_name.inspect}); __cycle_idx__ = __cycle_state__[__cycle_key__] ||= 0; __output__ << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; __cycle_state__[__cycle_key__] = __cycle_idx__ + 1\n"

      when IL::LABEL, IL::POP_INTERRUPT, IL::JUMP_IF_INTERRUPT, IL::POP_FORLOOP,
           IL::FOR_END, IL::FOR_NEXT, IL::JUMP_IF_EMPTY, IL::PUSH_FORLOOP, IL::POP,
           IL::IFCHANGED_CHECK
        @pc += 1
        "" # No-ops in structured code (IFCHANGED_CHECK handled by POP_CAPTURE)

      when IL::LOAD_TEMP
        # Load from temp generates expression - peek ahead to see if it's part of an if
        if peek_if_statement?
          generate_if_statement(indent)
        else
          generate_expression_statement(indent)
        end

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
      temp_code = ""
      if @temp_assignments
        @temp_assignments.each do |slot, temp_expr|
          temp_code << "#{prefix}__temp_#{slot}__ = #{expr_to_ruby(temp_expr)}\n"
        end
        @temp_assignments = nil
      end

      case terminator
      when :write_value
        expr_code = expr_to_ruby(expr)
        temp_code + "#{prefix}__output__ << ((__v__ = #{expr_code}).is_a?(String) ? __v__ : __output_string__.call(__v__))\n"
      when :assign
        var = @instructions[@pc - 1][1]
        temp_code + "#{prefix}__scope__.assign(#{var.inspect}, #{expr_to_ruby(expr)})\n"
      when :assign_local
        var = @instructions[@pc - 1][1]
        temp_code + "#{prefix}__scope__.assign_local(#{var.inspect}, #{expr_to_ruby(expr)})\n"
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

    # Build an expression tree from IL instructions
    # Returns [Expr, terminator_type]
    def build_expression
      stack = []

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
          stack << Expr.new(type: :lookup, children: [obj, key])
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
        when IL::CALL_FILTER
          argc = inst[2] || 0
          args = argc > 0 ? stack.pop(argc) : []
          input = stack.pop || Expr.new(type: :literal, value: nil)
          stack << Expr.new(type: :filter, value: inst[1], children: [input] + args)
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
          jump_target = inst[1]
          target_inst = @instructions[jump_target]
          # For short-circuit detection, check if CONST_TRUE/FALSE is followed by expression continuation
          # vs STORE_TEMP (which indicates case/when pattern where it sets a "matched" flag)
          next_after_target = @instructions[jump_target + 1]
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
                   IL::LOOKUP_COMMAND, IL::COMPARE, IL::CONTAINS, IL::BOOL_NOT, IL::IS_TRUTHY, IL::CALL_FILTER
                # Continue building expression for right operand
                case build_inst[0]
                when IL::CONST_INT then stack << Expr.new(type: :literal, value: build_inst[1]); @pc += 1
                when IL::CONST_STRING then stack << Expr.new(type: :literal, value: build_inst[1]); @pc += 1
                when IL::CONST_TRUE then stack << Expr.new(type: :literal, value: true); @pc += 1
                when IL::CONST_FALSE then stack << Expr.new(type: :literal, value: false); @pc += 1
                when IL::FIND_VAR then stack << Expr.new(type: :var, value: build_inst[1]); @pc += 1
                when IL::FIND_VAR_PATH then stack << Expr.new(type: :var_path, value: build_inst[1], children: build_inst[2].map { |k| Expr.new(type: :literal, value: k) }); @pc += 1
                when IL::LOOKUP_CONST_KEY
                  obj = stack.pop || Expr.new(type: :literal, value: nil)
                  stack << Expr.new(type: :lookup, value: build_inst[1], children: [obj])
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
            # This is 'or' short-circuit
            left = stack.pop || Expr.new(type: :literal, value: false)
            @pc += 1
            # Build right operand
            while @pc < jump_target
              build_inst = @instructions[@pc]
              break if build_inst.nil? || build_inst[0] == IL::JUMP
              case build_inst[0]
              when IL::FIND_VAR then stack << Expr.new(type: :var, value: build_inst[1]); @pc += 1
              when IL::FIND_VAR_PATH then stack << Expr.new(type: :var_path, value: build_inst[1], children: build_inst[2].map { |k| Expr.new(type: :literal, value: k) }); @pc += 1
              when IL::LOOKUP_CONST_KEY
                obj = stack.pop || Expr.new(type: :literal, value: nil)
                stack << Expr.new(type: :lookup, value: build_inst[1], children: [obj])
                @pc += 1
              when IL::IS_TRUTHY then @pc += 1
              when IL::JUMP then @pc = build_inst[1]; break
              else @pc += 1
              end
            end
            right = stack.pop || Expr.new(type: :literal, value: false)
            stack << Expr.new(type: :or, children: [left, right])
            # Skip IS_TRUTHY if present (the JUMP in right operand skips CONST_TRUE)
            if @instructions[@pc]&.[](0) == IL::IS_TRUTHY
              @pc += 1
            end
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

    # Convert expression tree to Ruby code
    def expr_to_ruby(expr)
      return "nil" if expr.nil?

      case expr.type
      when :literal
        expr.value.inspect
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
        "__compare__.call(#{left}, #{right}, #{expr.value.inspect})"
      when :contains
        left = expr_to_ruby(expr.children[0])
        right = expr_to_ruby(expr.children[1])
        "__contains__.call(#{left}, #{right})"
      when :not
        "!__is_truthy__.call(#{expr_to_ruby(expr.children[0])})"
      when :filter
        input = expr_to_ruby(expr.children[0])
        args = expr.children[1..].map { |a| expr_to_ruby(a) }
        if args.empty?
          "__call_filter__.call(#{expr.value.inspect}, #{input}, [], __scope__)"
        else
          "__call_filter__.call(#{expr.value.inspect}, #{input}, [#{args.join(', ')}], __scope__)"
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

    # Check if current position starts an if statement
    def peek_if_statement?
      i = 0
      while (next_inst = @instructions[@pc + i])
        case next_inst[0]
        when IL::IS_TRUTHY
          following = @instructions[@pc + i + 1]
          return following&.[](0) == IL::JUMP_IF_FALSE || following&.[](0) == IL::JUMP_IF_TRUE
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE
          return true
        when IL::FOR_INIT, IL::HALT, IL::WRITE_VALUE, IL::ASSIGN, IL::ASSIGN_LOCAL, IL::STORE_TEMP
          # These terminate the expression without being an if condition
          return false
        end
        i += 1
        break if i > 20 # Safety limit
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

      # Handle any pre-loop setup (optimizer may hoist expressions before FOR_INIT)
      while @pc < @instructions.length && @instructions[@pc][0] != IL::FOR_INIT
        inst = @instructions[@pc]
        case inst[0]
        when IL::FIND_VAR, IL::CONST_INT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE
          # Check if this is an expression followed by STORE_TEMP
          start_pc = @pc
          expr, term = build_expression
          if term == :store_temp
            # Get slot from STORE_TEMP instruction
            store_inst = @instructions[@pc]
            if store_inst && store_inst[0] == IL::STORE_TEMP
              slot = store_inst[1]
              @pc += 1
              pre_loop_code << "#{prefix}__temp_#{slot}__ = #{expr_to_ruby(expr)}\n" if expr
            end
          else
            # Not a store pattern, restore pc and break
            @pc = start_pc
            break
          end
        when IL::STORE_TEMP
          @pc += 1 # Skip orphaned STORE_TEMP
        else
          break
        end
      end

      # Consume: FOR_INIT
      for_init = @instructions[@pc]
      return nil unless for_init && for_init[0] == IL::FOR_INIT

      item_var = for_init[1]
      loop_name = for_init[2]
      reversed = for_init[3]
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
            result = generate_statement(indent + 2)
            body_code << result if result
          end
        when IL::JUMP_IF_INTERRUPT, IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END
          @pc += 1
          break if inst[0] == IL::JUMP_IF_INTERRUPT
        when IL::HALT
          break
        else
          result = generate_statement(indent + 2)
          body_code << result if result
        end
      end

      # Consume cleanup
      while @pc < @instructions.length
        case @instructions[@pc]&.[](0)
        when IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END, IL::JUMP, IL::LABEL
          @pc += 1
        else
          break
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
      parent_forloop = depth > 0 ? "__forloop_#{depth - 1}__" : "nil"

      code << "#{prefix}# for #{item_var}\n"
      code << "#{prefix}#{coll_var} = #{coll_ruby}\n"
      code << "#{prefix}#{coll_var} = #{coll_var}.to_a if #{coll_var}.respond_to?(:to_a) && !#{coll_var}.is_a?(String)\n"
      code << "#{prefix}#{coll_var} = #{coll_var}.reverse if #{reversed.inspect} && #{coll_var}.is_a?(Array)\n" if reversed
      code << "#{prefix}if #{coll_var}.is_a?(Array) && !#{coll_var}.empty?\n"
      code << "#{prefix}  __scope__.push_scope\n"
      code << "#{prefix}  #{forloop_var} = LiquidIL::ForloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{parent_forloop})\n"
      code << "#{prefix}  #{coll_var}.each_with_index do |#{item_var_internal}, #{idx_var}|\n"
      code << "#{prefix}    #{forloop_var}.index0 = #{idx_var}\n"
      code << "#{prefix}    __scope__.assign_local('forloop', #{forloop_var})\n"
      code << "#{prefix}    __scope__.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
      code << body_code
      code << "#{prefix}  end\n"
      code << "#{prefix}  __scope__.pop_scope\n"
      code << "#{prefix}end\n"

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
          then_code << result if result
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
            else_code << result if result
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

    # Evaluate generated Ruby code
    def eval_ruby(source)
      eval(source)
    rescue SyntaxError => e
      # puts "Syntax error: #{e.message}"
      # puts source.lines.each_with_index.map { |l, i| "#{i+1}: #{l}" }.join
      nil
    end
  end

  # StructuredCompiledTemplate wraps a compiled proc with VM fallback
  class StructuredCompiledTemplate
    attr_reader :source, :instructions, :spans, :compiled_source, :uses_vm

    def initialize(source, instructions, spans, context, compiled_result)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @uses_vm = !compiled_result.can_compile
    end

    def render(assigns = {}, render_errors: true, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = Scope.new(assigns, registers: @context&.registers&.dup || {}, strict_errors: @context&.strict_errors || false)
      scope.file_system = @context&.file_system
      scope.render_errors = render_errors

      if @uses_vm
        VM.execute(@instructions, scope, spans: @spans, source: @source)
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
