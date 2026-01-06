# frozen_string_literal: true

module LiquidIL
  # Pretty prints IL instructions in a readable format
  class PrettyPrinter
    COLORS = {
      opcode: "\e[1;36m",    # Bold cyan
      label: "\e[1;33m",     # Bold yellow
      string: "\e[32m",      # Green
      number: "\e[35m",      # Magenta
      comment: "\e[2;37m",   # Dim white
      reset: "\e[0m"
    }.freeze

    def initialize(instructions, color: true, source: nil, spans: nil)
      @instructions = instructions
      @color = color
      @source = source
      @spans = spans
      @label_names = build_label_names
    end

    def to_s
      lines = []
      last_source_span = nil  # Track last non-nil span
      @instructions.each_with_index do |inst, idx|
        # Emit source line when span changes to a new source location
        current_span = @spans && @spans[idx]
        if current_span && current_span != last_source_span
          slice = source_slice(idx)
          lines << "#{c(:comment)}         # #{slice}#{c(:reset)}" if slice
          last_source_span = current_span
        end

        lines << format_instruction(inst, idx)
      end
      lines.join("\n")
    end

    def print(io = $stdout)
      io.puts to_s
    end

    private

    def build_label_names
      names = {}
      label_count = 0
      @instructions.each do |inst|
        if inst[0] == IL::LABEL
          names[inst[1]] = "L#{label_count}"
          label_count += 1
        end
      end
      names
    end

    def format_instruction(inst, idx)
      opcode = inst[0]
      args = inst[1..]

      case opcode
      when IL::LABEL
        format_label(args[0], idx)
      when IL::WRITE_RAW
        format_simple("WRITE_RAW", [format_string(args[0])], idx)
      when IL::WRITE_VALUE
        format_simple("WRITE_VALUE", [], idx, comment: "pop → output")
      when IL::CONST_NIL
        format_simple("CONST_NIL", [], idx, comment: "→ nil")
      when IL::CONST_TRUE
        format_simple("CONST_TRUE", [], idx, comment: "→ true")
      when IL::CONST_FALSE
        format_simple("CONST_FALSE", [], idx, comment: "→ false")
      when IL::CONST_INT
        format_simple("CONST_INT", [format_number(args[0])], idx, comment: "→ #{args[0]}")
      when IL::CONST_FLOAT
        format_simple("CONST_FLOAT", [format_number(args[0])], idx, comment: "→ #{args[0]}")
      when IL::CONST_STRING
        format_simple("CONST_STRING", [format_string(args[0])], idx)
      when IL::CONST_RANGE
        format_simple("CONST_RANGE", [format_number(args[0]), format_number(args[1])], idx, comment: "→ #{args[0]}..#{args[1]}")
      when IL::CONST_EMPTY
        format_simple("CONST_EMPTY", [], idx, comment: "→ empty")
      when IL::CONST_BLANK
        format_simple("CONST_BLANK", [], idx, comment: "→ blank")
      when IL::FIND_VAR
        format_simple("FIND_VAR", [format_string(args[0])], idx, comment: "→ #{args[0]}")
      when IL::FIND_VAR_DYNAMIC
        format_simple("FIND_VAR_DYNAMIC", [], idx, comment: "pop name → value")
      when IL::LOOKUP_KEY
        format_simple("LOOKUP_KEY", [], idx, comment: "pop key, obj → obj[key]")
      when IL::LOOKUP_CONST_KEY
        format_simple("LOOKUP_CONST_KEY", [format_string(args[0])], idx, comment: "pop obj → obj.#{args[0]}")
      when IL::LOOKUP_COMMAND
        format_simple("LOOKUP_COMMAND", [format_string(args[0])], idx, comment: "pop → .#{args[0]}")
      when IL::PUSH_CAPTURE
        format_simple("PUSH_CAPTURE", [], idx)
      when IL::POP_CAPTURE
        format_simple("POP_CAPTURE", [], idx, comment: "→ captured string")
      when IL::JUMP
        format_jump("JUMP", args[0], idx)
      when IL::JUMP_IF_FALSE
        format_jump("JUMP_IF_FALSE", args[0], idx, comment: "pop, jump if falsy")
      when IL::JUMP_IF_TRUE
        format_jump("JUMP_IF_TRUE", args[0], idx, comment: "pop, jump if truthy")
      when IL::JUMP_IF_EMPTY
        format_jump("JUMP_IF_EMPTY", args[0], idx, comment: "peek, jump if empty")
      when IL::JUMP_IF_INTERRUPT
        format_jump("JUMP_IF_INTERRUPT", args[0], idx, comment: "jump if break/continue")
      when IL::HALT
        format_simple("HALT", [], idx, comment: "end execution")
      when IL::COMPARE
        format_simple("COMPARE", [":#{args[0]}"], idx, comment: "pop a, b → a #{op_symbol(args[0])} b")
      when IL::CONTAINS
        format_simple("CONTAINS", [], idx, comment: "pop a, b → a contains b")
      when IL::BOOL_NOT
        format_simple("BOOL_NOT", [], idx, comment: "pop → !value")
      when IL::IS_TRUTHY
        format_simple("IS_TRUTHY", [], idx, comment: "pop → bool")
      when IL::PUSH_SCOPE
        format_simple("PUSH_SCOPE", [], idx)
      when IL::POP_SCOPE
        format_simple("POP_SCOPE", [], idx)
      when IL::ASSIGN
        format_simple("ASSIGN", [format_string(args[0])], idx, comment: "pop → #{args[0]}")
      when IL::NEW_RANGE
        format_simple("NEW_RANGE", [], idx, comment: "pop end, start → range")
      when IL::CALL_FILTER
        format_simple("CALL_FILTER", [format_string(args[0]), args[1].to_s], idx, comment: "#{args[1]} args")
      when IL::FOR_INIT
        format_simple("FOR_INIT", format_for_init_args(args), idx)
      when IL::FOR_NEXT
        format_for_next(args, idx)
      when IL::FOR_END
        format_simple("FOR_END", [], idx)
      when IL::PUSH_FORLOOP
        format_simple("PUSH_FORLOOP", [], idx)
      when IL::POP_FORLOOP
        format_simple("POP_FORLOOP", [], idx)
      when IL::PUSH_INTERRUPT
        format_simple("PUSH_INTERRUPT", [":#{args[0]}"], idx)
      when IL::POP_INTERRUPT
        format_simple("POP_INTERRUPT", [], idx)
      when IL::INCREMENT
        format_simple("INCREMENT", [format_string(args[0])], idx)
      when IL::DECREMENT
        format_simple("DECREMENT", [format_string(args[0])], idx)
      when IL::CYCLE_STEP
        format_simple("CYCLE_STEP", [format_string(args[0]), args[1].inspect], idx)
      when IL::RENDER_PARTIAL
        format_simple("RENDER_PARTIAL", [format_string(args[0])], idx, comment: format_partial_comment(args[1], "isolated"))
      when IL::INCLUDE_PARTIAL
        format_simple("INCLUDE_PARTIAL", [format_string(args[0])], idx, comment: format_partial_comment(args[1], "shared"))
      when IL::TABLEROW_INIT
        format_simple("TABLEROW_INIT", format_tablerow_init_args(args), idx)
      when IL::TABLEROW_NEXT
        format_tablerow_next(args, idx)
      when IL::TABLEROW_END
        format_simple("TABLEROW_END", [], idx)
      when IL::DUP
        format_simple("DUP", [], idx, comment: "duplicate top")
      when IL::POP
        format_simple("POP", [], idx, comment: "discard top")
      when IL::STORE_TEMP
        format_simple("STORE_TEMP", [args[0].to_s], idx)
      when IL::LOAD_TEMP
        format_simple("LOAD_TEMP", [args[0].to_s], idx)
      when IL::NOOP
        format_simple("NOOP", [], idx)
      else
        format_simple(opcode.to_s, args.map(&:inspect), idx)
      end
    end

    def format_label(id, idx)
      name = @label_names[id] || "L?"
      "#{idx_prefix(idx)}  #{c(:label)}#{name}:#{c(:reset)}"
    end

    def format_simple(opcode, args, idx, comment: nil)
      line = "#{idx_prefix(idx)}     #{c(:opcode)}#{opcode.ljust(18)}#{c(:reset)}"
      args_str = args.join(", ")
      line += ljust_visible(args_str, 20) unless args.empty?
      line += " " * 20 if args.empty?
      line += format_comment(idx, comment)
      line
    end

    def format_comment(idx, extra = nil)
      return "" unless extra
      "  #{c(:comment)}# #{extra}#{c(:reset)}"
    end

    def format_jump(opcode, target, idx, comment: nil)
      target_name = if target.is_a?(Integer) && target < @instructions.length
        # Linked - find which label this points to
        @label_names.find { |_, v| @instructions.each_with_index.any? { |inst, i| inst[0] == IL::LABEL && inst[1] == _ && i == target } }&.last || "→#{target}"
      else
        @label_names[target] || "L?"
      end

      # Find actual label name for linked instructions
      if target.is_a?(Integer)
        @instructions.each_with_index do |inst, i|
          if inst[0] == IL::LABEL && i == target
            target_name = @label_names[inst[1]] || "L?"
            break
          end
        end
      end

      args_str = "#{c(:label)}#{target_name}#{c(:reset)}"
      line = "#{idx_prefix(idx)}     #{c(:opcode)}#{opcode.ljust(18)}#{c(:reset)}#{ljust_visible(args_str, 20)}"
      line += format_comment(idx, comment)
      line
    end

    def format_for_next(args, idx)
      cont = args[0]
      brk = args[1]
      cont_name = find_label_at(cont)
      brk_name = find_label_at(brk)
      args_str = "#{c(:label)}#{cont_name}#{c(:reset)}, #{c(:label)}#{brk_name}#{c(:reset)}"
      line = "#{idx_prefix(idx)}     #{c(:opcode)}#{"FOR_NEXT".ljust(18)}#{c(:reset)}#{ljust_visible(args_str, 20)}"
      line += format_comment(idx, "continue, break")
      line
    end

    def find_label_at(target)
      return "L?" unless target.is_a?(Integer)
      @instructions.each_with_index do |inst, i|
        if inst[0] == IL::LABEL && i == target
          return @label_names[inst[1]] || "L?"
        end
      end
      "→#{target}"
    end

    def format_for_init_args(args)
      var_name, loop_name, has_limit, has_offset, offset_continue, reversed = args
      parts = [format_string(var_name)]
      flags = []
      flags << "limit" if has_limit
      flags << "offset" if has_offset
      flags << "offset:continue" if offset_continue
      flags << "reversed" if reversed
      parts << flags.join(" ") unless flags.empty?
      parts
    end

    def format_tablerow_init_args(args)
      var_name, loop_name, has_limit, has_offset, cols = args
      parts = [format_string(var_name)]
      flags = []
      flags << "cols:#{cols}" if cols
      flags << "limit" if has_limit
      flags << "offset" if has_offset
      parts << flags.join(" ") unless flags.empty?
      parts
    end

    def format_tablerow_next(args, idx)
      cont = args[0]
      brk = args[1]
      cont_name = find_label_at(cont)
      brk_name = find_label_at(brk)
      args_str = "#{c(:label)}#{cont_name}#{c(:reset)}, #{c(:label)}#{brk_name}#{c(:reset)}"
      line = "#{idx_prefix(idx)}     #{c(:opcode)}#{"TABLEROW_NEXT".ljust(18)}#{c(:reset)}#{ljust_visible(args_str, 20)}"
      line += format_comment(idx, "continue, break")
      line
    end

    def format_string(s)
      "#{c(:string)}#{s.inspect}#{c(:reset)}"
    end

    def format_number(n)
      "#{c(:number)}#{n}#{c(:reset)}"
    end

    def idx_prefix(idx)
      "#{c(:comment)}[#{idx.to_s.rjust(3)}]#{c(:reset)}"
    end

    # Left-justify accounting for ANSI codes (which don't take visual space)
    def ljust_visible(str, width)
      visible_len = str.gsub(/\e\[[0-9;]*m/, "").length
      str + " " * [width - visible_len, 0].max
    end

    # Get source slice for instruction, if available
    def source_slice(idx)
      return nil unless @source && @spans && @spans[idx]
      start_pos, end_pos = @spans[idx]
      slice = @source[start_pos...end_pos]
      # Clean up for display: collapse whitespace, truncate if long
      slice = slice.gsub(/\s+/, " ").strip
      slice = slice[0, 40] + "..." if slice.length > 43
      slice
    end

    def op_symbol(op)
      case op
      when :eq then "=="
      when :ne then "!="
      when :lt then "<"
      when :le then "<="
      when :gt then ">"
      when :ge then ">="
      else op.to_s
      end
    end

    def format_partial_comment(args, base)
      return base unless args.is_a?(Hash) && !args.empty?
      parts = [base]
      parts << "for:#{args['__for__']}" if args["__for__"]
      parts << "with:#{args['__with__']}" if args["__with__"]
      parts << "as:#{args['__as__']}" if args["__as__"]
      # Show other args
      other_args = args.reject { |k, _| k.start_with?("__") }
      parts << other_args.map { |k, v| "#{k}:#{v.inspect}" }.join(", ") unless other_args.empty?
      parts.join(", ")
    end

    def c(name)
      @color ? COLORS[name] : ""
    end
  end

  class Template
    # Pretty print the IL instructions
    def pretty_print(color: true)
      PrettyPrinter.new(@instructions, color: color, source: @source, spans: @spans).to_s
    end

    def dump_il(io = $stdout, color: true)
      io.puts pretty_print(color: color)
    end
  end
end
