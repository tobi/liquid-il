# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Direct IL-to-expression lowering. CodeFragment metadata travels beside
    # Ruby source without introducing a second expression AST.
    module ExpressionEmitter
    # Build a Ruby expression directly from IL instructions.
    # Returns [ruby_source, terminator_type].
    def build_expression
      # A lightweight fragment stack: still direct lowering (no expression
      # AST), but each source expression carries the semantic facts output
      # codegen needs instead of being classified from generated text.
      stack = FragmentStack.new

      while @pc < @instructions.length
        inst = @instructions[@pc]

        case inst[0]
        when IL::CONST_INT
          stack.push_fragment(inst[1].inspect, value_type: :numeric)
          @pc += 1
        when IL::CONST_FLOAT
          # Handle special Float values (NaN, Infinity)
          val = inst[1]
          if val.nan?
            stack.push_fragment("Float::NAN", value_type: :numeric)
          elsif val.infinite? == 1
            stack.push_fragment("Float::INFINITY", value_type: :numeric)
          elsif val.infinite? == -1
            stack.push_fragment("-Float::INFINITY", value_type: :numeric)
          else
            stack.push_fragment(val.inspect, value_type: :numeric)
          end
          @pc += 1
        when IL::CONST_STRING
          stack.push_fragment(lit(inst[1]), value_type: :string)
          @pc += 1
        when IL::CONST_TRUE
          stack.push_fragment("true", value_type: :boolean)
          @pc += 1
        when IL::CONST_FALSE
          stack.push_fragment("false", value_type: :boolean)
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
          stack << CodeFragment.new(scope_lookup(inst[1]),
            origin: loop_item_binding?(inst[1]) ? :loop_item : nil)
          @pc += 1
        when IL::FIND_SELF
          if @scope_bindings && (self_binding = @scope_bindings["self"])
            stack << self_binding
          else
            record_dynamic_read
            stack << "_S.lookup_self"
          end
          @pc += 1
        when IL::FIND_VAR_PATH
          stack << generate_var_path_expr(inst[1], inst[2])
          @pc += 1
        when IL::FIND_VAR_DYNAMIC
          record_dynamic_read
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
          when "first", "last"
            stack << "_H.lookup(#{obj_ruby}, #{cmd.inspect})"
          else
            stack << "_H.lookup(#{obj_ruby}, #{cmd.inspect})"
          end
          @pc += 1
        when IL::COMPARE
          right_ruby = stack.pop || "nil"
          left_ruby = stack.pop || "nil"
          op = inst[1]
          # Inline numeric comparisons: skip _H.cmp for numeric literals
          if NUMERIC_COMPARE_OPS.key?(op) && right_ruby.value_type == :numeric
            ruby_op = COMPARE_OPS[op]
            # Known numeric fragments can use Ruby's direct comparison. Unknown
            # values retain the canonical Liquid comparison helper.
            if left_ruby.value_type == :numeric
              stack.push_fragment("(#{left_ruby} || 0) #{ruby_op} #{right_ruby}", value_type: :boolean)
            else
              stack.push_fragment("_H.cmp(#{left_ruby}, #{right_ruby}, #{op.inspect}, _O, #{@current_file_lit.inspect})", value_type: :boolean)
            end
          else
            stack.push_fragment("_H.cmp(#{left_ruby}, #{right_ruby}, #{op.inspect}, _O, #{@current_file_lit.inspect})", value_type: :boolean)
          end
          @pc += 1
        when IL::CONTAINS
          right_ruby = stack.pop || "nil"
          left_ruby = stack.pop || "nil"
          stack.push_fragment("_H.ct(#{left_ruby}, #{right_ruby})", value_type: :boolean)
          @pc += 1
        when IL::BOOL_NOT
          operand_ruby = stack.pop || "false"
          stack.push_fragment("((_t = #{operand_ruby}); _t.nil? || _t == false || _t == \"\")", value_type: :boolean)
          @pc += 1
        when IL::BOOL_AND
          right_ruby = stack.pop || "false"
          left_ruby = stack.pop || "false"
          stack.push_fragment("((#{inline_truthy(left_ruby)}) && (#{inline_truthy(right_ruby)}))", value_type: :boolean)
          @pc += 1
        when IL::BOOL_OR
          right_ruby = stack.pop || "false"
          left_ruby = stack.pop || "false"
          stack.push_fragment("((#{inline_truthy(left_ruby)}) || (#{inline_truthy(right_ruby)}))", value_type: :boolean)
          @pc += 1
        when IL::IS_TRUTHY
          # Conditions are truthy-wrapped at IF emission (inline_truthy); the
          # marker itself adds nothing to the value expression.
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
          require_codegen_helper(:utils)
          stack.push_fragment("_U.ce?(#{right_ruby}, #{left_ruby})", value_type: :boolean)
          @pc += 1
        when IL::BUILD_HASH
          count = inst[1]
          pairs = stack.pop(count * 2)
          stack << "{" + pairs.each_slice(2).map { |k, v| "#{k} => #{v}" }.join(", ") + "}"
          @pc += 1
        when IL::CALL_FILTER
          argc = inst[2] || 0
          args = argc > 0 ? stack.pop(argc) : []
          input_ruby = stack.pop || "nil"
          stack << emit_filter_call(inst[1], input_ruby, args, inst[3] || 1)
          @pc += 1
        when IL::WRITE_VALUE
          @pc += 1
          return [stack.last, :write_value]
        when IL::ASSIGN
          @pc += 1
          return [stack.last, :assign]
        when IL::ASSIGN_LOCAL
          @pc += 1
          return [stack.last, :assign_local]
        when IL::IF
          # Structured conditional marker: the finished condition is on the
          # stack. Leave @pc at the IF so the caller reads its negate flag.
          return [stack.last, :if]
        else
          # Unknown or terminating instruction
          break
        end
      end

      [stack.last, :none]
    end

    # Generate variable path access (a.b.c)
    def generate_var_path_expr(var, path)
      record_parentloop_use if var == "forloop" && path.first.to_s == "parentloop"
      result = CodeFragment.new(scope_lookup_pathed(var),
        origin: loop_item_binding?(var) ? :loop_item : nil)
      path.each do |key|
        result = inline_lookup(result, key)
      end
      # Preserve the existing direct-to_s fast path explicitly: a single
      # constant-key read from a compiler-owned loop item local.
      simple_loop_lookup = loop_item_binding?(var) && path.length == 1 && path[0].to_s.match?(/\A\w+\z/)
      CodeFragment.new(result, output_policy: simple_loop_lookup ? :to_s : :liquid)
    end

    end
  end
end
