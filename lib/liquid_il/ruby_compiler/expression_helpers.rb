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
            return "_H.bl(#{base}, #{literal_ruby(next_inst)}, _S)"
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
        when IL::CONST_EMPTY then "LiquidIL::EmptyLiteral.instance"
        when IL::CONST_BLANK then "LiquidIL::BlankLiteral.instance"
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

      def consume_property_chain_ruby(current)
        while @pc < @instructions.length
          inst = @instructions[@pc]
          break unless inst

          case inst[0]
          when IL::LOOKUP_CONST_KEY
            current = inline_lookup(current, inst[1])
            @pc += 1
          when IL::LOOKUP_CONST_PATH
            inst[1].each { |key| current = inline_lookup(current, key) }
            @pc += 1
          when IL::CONST_STRING, IL::CONST_INT
            if @instructions[@pc + 1]&.[](0) == IL::LOOKUP_KEY
              current = "_H.bl(#{current}, #{literal_ruby(inst)}, _S)"
              @pc += 2
            else
              break
            end
          else
            break
          end
        end
        current
      end

      def compare_ruby(left_ruby, right_ruby, op)
        if NUMERIC_COMPARE_OPS.key?(op) && right_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
          ruby_op = COMPARE_OPS[op]
          if left_ruby.include?("&.size") || left_ruby.include?("&.length") || left_ruby.match?(/\A-?[0-9]+\.?[0-9]*\z/)
            "(#{left_ruby} || 0) #{ruby_op} #{right_ruby}"
          else
            "((_t = #{left_ruby}); _t.is_a?(Numeric) && _t #{ruby_op} #{right_ruby})"
          end
        else
          "_H.cmp(#{left_ruby}, #{right_ruby}, #{op.inspect}, _O, _F)"
        end
      end

      def build_single_and_operand_ruby(end_target)
        inst = @instructions[@pc]
        return nil unless inst&.[](0) == IL::FIND_VAR

        expr_ruby = ruby_var_reference(inst[1])
        @pc += 1
        expr_ruby = consume_property_chain_ruby(expr_ruby)

        next_inst = @instructions[@pc]
        if next_inst && [IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT,
                         IL::CONST_STRING, IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK].include?(next_inst[0])
          const_ruby = literal_ruby(next_inst)
          @pc += 1

          compare_inst = @instructions[@pc]
          if compare_inst&.[](0) == IL::COMPARE
            expr_ruby = compare_ruby(expr_ruby, const_ruby, compare_inst[1])
            @pc += 1
          elsif compare_inst&.[](0) == IL::CONTAINS
            expr_ruby = "_H.ct(#{expr_ruby}, #{const_ruby})"
            @pc += 1
          end
        end

        check_inst = @instructions[@pc]
        if check_inst&.[](0) == IL::JUMP_IF_FALSE
          @pc += 1
          expr_ruby
        elsif check_inst&.[](0) == IL::JUMP_IF_TRUE
          jit_target = check_inst[1]
          jit_actual = jit_target
          while @instructions[jit_actual]&.[](0) == IL::LABEL
            jit_actual += 1
          end
          if @instructions[jit_actual]&.[](0) == IL::CONST_TRUE
            nested_or_operands = [expr_ruby]
            @pc += 1
            while @pc < end_target
              nested_inst = @instructions[@pc]
              break if nested_inst.nil?

              case nested_inst[0]
              when IL::FIND_VAR
                operand = ruby_var_reference(nested_inst[1])
                @pc += 1
                operand = consume_property_chain_ruby(operand)
                nested_or_operands << operand
                @pc += 1 if @instructions[@pc]&.[](0) == IL::JUMP_IF_TRUE
              when IL::JUMP
                @pc = nested_inst[1]
                break
              when IL::CONST_TRUE, IL::LABEL
                @pc += 1
              else
                @pc += 1
              end
            end
            nested_or_operands.map { |c| "(#{inline_truthy(c)})" }.join(" || ")
          else
            expr_ruby
          end
        else
          expr_ruby
        end
      end

      def build_and_right_operand_ruby(end_target)
        and_operands = []
        while @pc < end_target
          inst = @instructions[@pc]
          break if inst.nil? || inst[0] == IL::JUMP

          case inst[0]
          when IL::FIND_VAR
            operand = build_single_and_operand_ruby(end_target)
            and_operands << operand if operand
          when IL::CONST_TRUE
            and_operands << "true"
            @pc += 1
          when IL::CONST_FALSE
            and_operands << "false"
            @pc += 1
          when IL::LABEL
            @pc += 1
          else
            @pc += 1
          end
        end

        result = and_operands.first || "false"
        and_operands[1..].each do |operand|
          result = "((#{inline_truthy(result)}) && (#{inline_truthy(operand)}))"
        end
        result
      end

      # Build a complete OR operand expression as Ruby source starting from FIND_VAR.
      # Handles simple vars, comparisons, property chains, and nested AND chains
      # without constructing a separate expression tree.
      def build_or_operand_ruby(var_name)
        var_ruby = ruby_var_reference(var_name)
        @pc += 1
        var_ruby = consume_property_chain_ruby(var_ruby)

        next_inst = @instructions[@pc]
        return nil if next_inst.nil?

        case next_inst[0]
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
            right = build_and_right_operand_ruby(jif_target)
            @pc = @instructions[@pc][1] if @instructions[@pc]&.[](0) == IL::JUMP
            @pc += 1 if @instructions[@pc]&.[](0) == IL::CONST_TRUE
            "((#{inline_truthy(var_ruby)}) && (#{inline_truthy(right)}))"
          else
            nil
          end
        when IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_NIL, IL::CONST_EMPTY, IL::CONST_BLANK
          const_ruby = literal_ruby(next_inst)
          @pc += 1
          compare_inst = @instructions[@pc]
          if compare_inst&.[](0) == IL::COMPARE
            result = compare_ruby(var_ruby, const_ruby, compare_inst[1])
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

    end
  end
end
