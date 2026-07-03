# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Direct Ruby-source expression helpers used by loop/tablerow lowering.
    #
    # These helpers keep Ruby codegen on one representation: strings of Ruby
    # source. The autoresearch prototype still had a second Expr tree path for
    # loop modifiers; this module removes that duplicate representation.
    module ExpressionHelpers
      # Build one value expression for loop/tablerow modifiers.
      #
      # The compiler now has a single expression representation in the Ruby codegen
      # layer: Ruby source strings. Older versions built small Expr trees here and
      # converted them later via expr_to_ruby, which duplicated the main
      # build_expression lowering path. Keep this method intentionally narrow: it
      # consumes exactly one value when possible and delegates complex cases to the
      # canonical direct-Ruby expression builder.
      def build_single_value_expression
        inst = @instructions[@pc]
        return nil if inst.nil?

        case inst[0]
        when IL::CONST_INT
          next_inst = @instructions[@pc + 1]
          next_next = @instructions[@pc + 2]
          if (next_inst&.[](0) == IL::CONST_INT || next_inst&.[](0) == IL::CONST_FLOAT) && next_next&.[](0) == IL::NEW_RANGE
            start_val = inst[1].inspect
            end_val = literal_ruby(next_inst)
            @pc += 3
            return "LiquidIL::RangeValue.new(#{start_val}, #{end_val})"
          end
          @pc += 1
          inst[1].inspect
        when IL::CONST_FLOAT
          @pc += 1
          float_literal_ruby(inst[1])
        when IL::CONST_STRING
          @pc += 1
          inst[1].inspect
        when IL::CONST_TRUE
          @pc += 1
          "true"
        when IL::CONST_FALSE
          @pc += 1
          "false"
        when IL::CONST_NIL
          @pc += 1
          "nil"
        when IL::CONST_EMPTY
          @pc += 1
          "LiquidIL::EmptyLiteral.instance"
        when IL::CONST_BLANK
          @pc += 1
          "LiquidIL::BlankLiteral.instance"
        when IL::CONST_RANGE
          @pc += 1
          "LiquidIL::RangeValue.new(#{inst[1]}, #{inst[2]})"
        when IL::FIND_VAR
          next_inst = @instructions[@pc + 1]
          next_next = @instructions[@pc + 2]
          base = ruby_var_reference(inst[1])

          if next_inst&.[](0) == IL::CONST_INT && next_next&.[](0) == IL::NEW_RANGE
            @pc += 3
            return "LiquidIL::RangeValue.new(#{base}, #{next_inst[1].inspect})"
          end

          if next_inst&.[](0) == IL::FIND_VAR && next_next&.[](0) == IL::NEW_RANGE
            @pc += 3
            return "LiquidIL::RangeValue.new(#{base}, #{ruby_var_reference(next_inst[1])})"
          end

          if next_inst&.[](0) == IL::LOOKUP_CONST_KEY
            current = base
            @pc += 1
            while @instructions[@pc]&.[](0) == IL::LOOKUP_CONST_KEY
              current = inline_lookup(current, @instructions[@pc][1])
              @pc += 1
            end
            return current
          end

          if (next_inst&.[](0) == IL::CONST_STRING || next_inst&.[](0) == IL::CONST_INT) && next_next&.[](0) == IL::LOOKUP_KEY
            @pc += 3
            return "_H.bl(#{base}, #{literal_ruby(next_inst)})"
          end

          @pc += 1
          base
        when IL::FIND_VAR_PATH
          @pc += 1
          generate_var_path_expr(inst[1], inst[2])
        when IL::LOAD_TEMP
          @pc += 1
          "__temp_#{inst[1]}__"
        else
          expr, = build_expression
          expr
        end
      end

      def ruby_var_reference(name)
        @loop_var_aliases[name] || "_S.lookup(#{name.inspect})"
      end

      def literal_ruby(inst)
        case inst[0]
        when IL::CONST_INT then inst[1].inspect
        when IL::CONST_FLOAT then float_literal_ruby(inst[1])
        when IL::CONST_STRING then inst[1].inspect
        when IL::CONST_TRUE then "true"
        when IL::CONST_FALSE then "false"
        when IL::CONST_NIL then "nil"
        else "nil"
        end
      end

      def float_literal_ruby(value)
        if value.nan?
          "Float::NAN"
        elsif value.infinite? == 1
          "Float::INFINITY"
        elsif value.infinite? == -1
          "-Float::INFINITY"
        else
          value.inspect
        end
      end

      # Continue an OR chain when @pc is positioned at JUMP_IF_TRUE and the left
      # operand Ruby has already been built. This follows the IL jump shape rather
      # than guessing from adjacent operands: JUMP_IF_TRUE must target CONST_TRUE,
      # and terminal operands may jump to the expression merge point.
      def build_or_chain_from_left(left_ruby)
        operands = [left_ruby]

        while @instructions[@pc]&.[](0) == IL::JUMP_IF_TRUE
          jump_target = @instructions[@pc][1]
          actual_target = jump_target
          while @instructions[actual_target]&.[](0) == IL::LABEL
            actual_target += 1
          end
          return nil unless @instructions[actual_target]&.[](0) == IL::CONST_TRUE

          @pc += 1
          inst = @instructions[@pc]
          return nil if inst.nil?

          operand = case inst[0]
          when IL::FIND_VAR
            build_or_operand_ruby(inst[1])
          when IL::FIND_VAR_PATH
            @pc += 1
            build_or_operand_from_value(generate_var_path_expr(inst[1], inst[2]))
          when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE,
               IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK
            @pc += 1
            literal_ruby(inst)
          else
            nil
          end
          return nil unless operand

          operands << operand

          if @instructions[@pc]&.[](0) == IL::JUMP
            @pc = @instructions[@pc][1]
          end
          if @instructions[@pc]&.[](0) == IL::CONST_TRUE
            @pc += 1
            @pc = @instructions[@pc][1] if @instructions[@pc]&.[](0) == IL::JUMP
          end
        end

        operands.map { |c| "(#{inline_truthy(c)})" }.join(" || ")
      end

      # Continue building an OR operand after its first value has been consumed.
      # Handles simple values, comparisons, and nested AND chains without constructing
      # a separate expression tree.
      def build_or_operand_from_value(var_ruby)
        next_inst = @instructions[@pc]
        return var_ruby if next_inst.nil?

        case next_inst[0]
        when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE,
             IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK
          # Variable compared to a constant: var OP const (e.g., items == blank)
          const_ruby = literal_ruby(next_inst)
          @pc += 1
          compare_inst = @instructions[@pc]
          if compare_inst&.[](0) == IL::COMPARE
            cmp_op = compare_inst[1]
            @pc += 1
            # Skip JUMP to end of or-block
            @pc = @instructions[@pc][1] if @instructions[@pc]&.[](0) == IL::JUMP
            return "_H.cmp(#{var_ruby}, #{const_ruby}, #{cmp_op.inspect}, _O, _F)"
          end
          return nil
        when IL::JUMP_IF_TRUE
          jit_target = next_inst[1]
          jit_actual = jit_target
          while @instructions[jit_actual]&.[](0) == IL::LABEL
            jit_actual += 1
          end
          if @instructions[jit_actual]&.[](0) == IL::CONST_TRUE
            @pc += 1
            var_ruby
          else
            nil
          end
        when IL::JUMP_IF_FALSE
          jif_target = next_inst[1]
          jif_actual = jif_target
          while @instructions[jif_actual]&.[](0) == IL::LABEL
            jif_actual += 1
          end
          if @instructions[jif_actual]&.[](0) == IL::CONST_FALSE
            @pc += 1
            and_parts = [var_ruby]
            while @pc < jif_target
              and_inst = @instructions[@pc]
              break if and_inst.nil? || and_inst[0] == IL::JUMP
              case and_inst[0]
              when IL::FIND_VAR
                and_parts << ruby_var_reference(and_inst[1])
                @pc += 1
              when IL::FIND_VAR_PATH
                and_parts << generate_var_path_expr(and_inst[1], and_inst[2])
                @pc += 1
              when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE,
                   IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK
                and_parts << literal_ruby(and_inst)
                @pc += 1
              when IL::COMPARE
                right_ruby = and_parts.pop || "nil"
                left_ruby = and_parts.pop || "nil"
                cmp_op = and_inst[1]
                if NUMERIC_COMPARE_OPS.key?(cmp_op) && right_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
                  ruby_op = COMPARE_OPS[cmp_op]
                  if left_ruby.include?("&.size") || left_ruby.include?("&.length") ||
                     left_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
                    and_parts << "(#{left_ruby} || 0) #{ruby_op} #{right_ruby}"
                  else
                    and_parts << "((_t = #{left_ruby}); _t = _t.to_liquid_value; _t.is_a?(Numeric) && _t #{ruby_op} #{right_ruby})"
                  end
                else
                  and_parts << "_H.cmp(#{left_ruby}, #{right_ruby}, #{cmp_op.inspect}, _O, _F)"
                end
                @pc += 1
              when IL::CONTAINS
                right_ruby = and_parts.pop || "nil"
                left_ruby = and_parts.pop || "nil"
                and_parts << "_H.ct(#{left_ruby}, #{right_ruby})"
                @pc += 1
              when IL::JUMP_IF_TRUE
                part = and_parts.pop || "false"
                part = build_or_chain_from_left(part)
                return nil unless part
                and_parts << part
              when IL::JUMP_IF_FALSE
                @pc += 1
              else
                @pc += 1
              end
            end
            @pc = @instructions[@pc][1] if @instructions[@pc]&.[](0) == IL::JUMP
            @pc += 1 if @instructions[@pc]&.[](0) == IL::CONST_TRUE
            and_parts.map { |c| "(#{inline_truthy(c)})" }.join(" && ")
          else
            nil
          end
        when IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_NIL
          const_ruby = literal_ruby(next_inst)
          @pc += 1
          compare_inst = @instructions[@pc]
          if compare_inst&.[](0) == IL::COMPARE
            cmp_op = compare_inst[1]
            if NUMERIC_COMPARE_OPS.key?(cmp_op) && const_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
              ruby_op = COMPARE_OPS[cmp_op]
              if var_ruby.include?("&.size") || var_ruby.include?("&.length")
                result = "(#{var_ruby} || 0) #{ruby_op} #{const_ruby}"
              else
                result = "((_t = #{var_ruby}); _t = _t.to_liquid_value; _t.is_a?(Numeric) && _t #{ruby_op} #{const_ruby})"
              end
            else
              result = "_H.cmp(#{var_ruby}, #{const_ruby}, #{cmp_op.inspect}, _O, _F)"
            end
            @pc += 1
          elsif compare_inst&.[](0) == IL::CONTAINS
            result = "_H.ct(#{var_ruby}, #{const_ruby})"
            @pc += 1
          else
            result = var_ruby
          end
          @pc = @instructions[@pc][1] if @instructions[@pc]&.[](0) == IL::JUMP
          result
        when IL::JUMP
          @pc = next_inst[1]
          var_ruby
        else
          var_ruby
        end
      end

      # Build a complete OR operand expression as Ruby source starting from FIND_VAR.
      def build_or_operand_ruby(var_name)
        @pc += 1
        build_or_operand_from_value(ruby_var_reference(var_name))
      end

    end
  end
end
