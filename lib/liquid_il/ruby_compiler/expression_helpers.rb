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

    end
  end
end
