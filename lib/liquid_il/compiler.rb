# frozen_string_literal: true

module LiquidIL
  # Compiler - wraps parser and provides optimization passes
  class Compiler
    attr_reader :source

    def initialize(source, **options)
      @source = source
      @options = options
      @partial_loader = @options[:partial_loader]
      file_system_loader = @options[:file_system]
      if !@partial_loader && file_system_loader && file_system_loader.respond_to?(:read)
        @partial_loader = file_system_loader
      end

      @inline_enabled = @options.key?(:inline_partials) ? @options[:inline_partials] : true

      if inline_partials_enabled?
        @inline_partial_stack = Array(@options[:inline_partial_stack])
        @inline_cache = (@options[:inline_partial_cache] ||= {})
      else
        @inline_partial_stack = []
        @inline_cache = {}
      end
    end

    def compile
      parser = Parser.new(@source)
      instructions = parser.parse
      spans = parser.builder.spans

      lower_const_partials(instructions)

      # Optional optimization passes
      if @options[:optimize]
        optimize(instructions, spans)
      end

      IL.link(instructions)

      { instructions: instructions, spans: spans }
    end

    private

    def optimize(instructions, spans)
      # Optimization pass 1: Fold constant operations
      fold_const_ops(instructions, spans)

      # Optimization pass 2: Fold constant filters
      fold_const_filters(instructions, spans)

      # Optimization pass 3: Fold constant output writes
      fold_const_writes(instructions, spans)

      # Optimization pass 4: Collapse chained constant lookups
      collapse_const_paths(instructions, spans)

      # Optimization pass 5: Collapse FIND_VAR + LOOKUP_CONST_PATH
      collapse_find_var_paths(instructions, spans)

      # Optimization pass 6: Remove redundant IS_TRUTHY on boolean ops
      remove_redundant_is_truthy(instructions, spans)

      # Optimization pass 7: Remove no-ops
      remove_noops(instructions, spans)

      # Optimization pass 8: Remove jumps to the immediately following label
      remove_jump_to_next_label(instructions, spans)

      # Optimization pass 9: Merge consecutive WRITE_RAW
      merge_raw_writes(instructions, spans)

      # Optimization pass 10: Remove unreachable code after unconditional jumps
      remove_unreachable(instructions, spans)

      # Optimization pass 11: Re-merge WRITE_RAW after other removals
      merge_raw_writes(instructions, spans)

      # Optimization pass 12: Fold constant capture blocks into direct assigns
      fold_const_captures(instructions, spans)

      # Optimization pass 13: Remove empty WRITE_RAW (no observable output)
      remove_empty_raw_writes(instructions, spans)

      instructions
    end

    def fold_const_ops(instructions, spans)
      i = 0
      while i < instructions.length
        inst = instructions[i]
        opcode = inst[0]

        if (const1 = const_value(inst))
          val1 = const1[1]
          # CONST + IS_TRUTHY / BOOL_NOT
          if i + 1 < instructions.length
            next_inst = instructions[i + 1]
            case next_inst[0]
            when IL::IS_TRUTHY
              truthy = const_evaluator.truthy?(val1)
              instructions[i] = truthy ? [IL::CONST_TRUE] : [IL::CONST_FALSE]
              spans[i] = spans[i + 1]
              instructions.delete_at(i + 1)
              spans.delete_at(i + 1)
              next
            when IL::BOOL_NOT
              truthy = const_evaluator.truthy?(val1)
              instructions[i] = truthy ? [IL::CONST_FALSE] : [IL::CONST_TRUE]
              spans[i] = spans[i + 1]
              instructions.delete_at(i + 1)
              spans.delete_at(i + 1)
              next
            when IL::JUMP_IF_FALSE
              truthy = const_evaluator.truthy?(val1)
              if truthy
                # Never jump: remove both
                instructions.delete_at(i + 1)
                spans.delete_at(i + 1)
                instructions.delete_at(i)
                spans.delete_at(i)
                next
              else
                # Always jump: replace with JUMP
                instructions[i] = [IL::JUMP, next_inst[1]]
                spans[i] = spans[i + 1]
                instructions.delete_at(i + 1)
                spans.delete_at(i + 1)
                next
              end
            when IL::JUMP_IF_TRUE
              truthy = const_evaluator.truthy?(val1)
              if truthy
                instructions[i] = [IL::JUMP, next_inst[1]]
                spans[i] = spans[i + 1]
                instructions.delete_at(i + 1)
                spans.delete_at(i + 1)
                next
              else
                instructions.delete_at(i + 1)
                spans.delete_at(i + 1)
                instructions.delete_at(i)
                spans.delete_at(i)
                next
              end
            end
          end

          # CONST, CONST, (COMPARE/CASE_COMPARE/CONTAINS)
          if i + 2 < instructions.length
            inst2 = instructions[i + 1]
            inst3 = instructions[i + 2]
            if (const2 = const_value(inst2))
              val2 = const2[1]
              case inst3[0]
              when IL::COMPARE
                result = safe_compare(val1, val2, inst3[1])
                if result != nil
                  instructions[i] = result ? [IL::CONST_TRUE] : [IL::CONST_FALSE]
                  spans[i] = spans[i + 2]
                  instructions.delete_at(i + 2)
                  spans.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  spans.delete_at(i + 1)
                  next
                end
              when IL::CASE_COMPARE
                result = safe_case_compare(val1, val2)
                if result != nil
                  instructions[i] = result ? [IL::CONST_TRUE] : [IL::CONST_FALSE]
                  spans[i] = spans[i + 2]
                  instructions.delete_at(i + 2)
                  spans.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  spans.delete_at(i + 1)
                  next
                end
              when IL::CONTAINS
                result = safe_contains(val1, val2)
                if result != nil
                  instructions[i] = result ? [IL::CONST_TRUE] : [IL::CONST_FALSE]
                  spans[i] = spans[i + 2]
                  instructions.delete_at(i + 2)
                  spans.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  spans.delete_at(i + 1)
                  next
                end
              end
            end
          end
        end

        i += 1
      end
    end

    def fold_const_writes(instructions, spans)
      i = 0
      while i < instructions.length - 1
        inst = instructions[i]
        if (const_val = const_value(inst)) && instructions[i + 1][0] == IL::WRITE_VALUE
          instructions[i] = [IL::WRITE_RAW, Utils.output_string(const_val[1])]
          spans[i] = spans[i + 1]
          instructions.delete_at(i + 1)
          spans.delete_at(i + 1)
        else
          i += 1
        end
      end
    end

    def fold_const_filters(instructions, spans)
      i = 0
      while i < instructions.length
        inst = instructions[i]
        if inst[0] == IL::CALL_FILTER
          name = inst[1].to_s
          argc = inst[2]
          if SAFE_FOLD_FILTERS.include?(name)
            collected = collect_const_values(instructions, i - 1, argc + 1)
            if collected
              values, start_idx = collected
              input = values[0]
              args = values[1..]
              result = const_evaluator.filter(name, input, args)
              if result
                const_inst = const_instruction_for(result)
                if const_inst
                  first = start_idx + 1
                  instructions[first] = const_inst
                  spans[first] = spans[i]
                  delete_count = i - first
                  instructions.slice!(first + 1, delete_count)
                  spans.slice!(first + 1, delete_count)
                  i = first + 1
                  next
                end
              end
            end
          end
        end
        i += 1
      end
    end

    def remove_noops(instructions, spans)
      i = 0
      while i < instructions.length
        if instructions[i][0] == IL::NOOP
          instructions.delete_at(i)
          spans.delete_at(i)
        else
          i += 1
        end
      end
    end

    def remove_redundant_is_truthy(instructions, spans)
      i = 1
      while i < instructions.length
        if instructions[i][0] == IL::IS_TRUTHY
          prev = instructions[i - 1][0]
          if prev == IL::COMPARE || prev == IL::CASE_COMPARE || prev == IL::CONTAINS || prev == IL::BOOL_NOT
            instructions.delete_at(i)
            spans.delete_at(i)
            next
          end
        end
        i += 1
      end
    end

    def collapse_find_var_paths(instructions, spans)
      i = 0
      while i < instructions.length - 1
        inst = instructions[i]
        next_inst = instructions[i + 1]
        if inst[0] == IL::FIND_VAR && next_inst[0] == IL::LOOKUP_CONST_PATH
          instructions[i] = [IL::FIND_VAR_PATH, inst[1], next_inst[1]]
          spans[i] = spans[i + 1]
          instructions.delete_at(i + 1)
          spans.delete_at(i + 1)
        else
          i += 1
        end
      end
    end

    def collect_const_values(instructions, end_idx, count)
      values = []
      idx = end_idx
      while values.length < count
        return nil if idx < 0
        inst = instructions[idx]
        if (const = const_value(inst))
          values.unshift(const[1])
          idx -= 1
        elsif inst[0] == IL::BUILD_HASH
          pair_count = inst[1]
          pair_result = collect_const_values(instructions, idx - 1, pair_count * 2)
          return nil unless pair_result
          pair_values, idx = pair_result
          hash = {}
          i = 0
          while i < pair_values.length
            key = pair_values[i]
            value = pair_values[i + 1]
            hash[key.to_s] = value
            i += 2
          end
          values.unshift(hash)
        else
          return nil
        end
      end
      [values, idx]
    end

    def collapse_const_paths(instructions, spans)
      i = 0
      while i < instructions.length - 1
        inst = instructions[i]
        if inst[0] == IL::LOOKUP_CONST_KEY
          path = [inst[1]]
          j = i + 1
          while j < instructions.length && instructions[j][0] == IL::LOOKUP_CONST_KEY
            path << instructions[j][1]
            j += 1
          end

          if path.length > 1
            instructions[i] = [IL::LOOKUP_CONST_PATH, path]
            delete_count = j - i - 1
            instructions.slice!(i + 1, delete_count)
            spans.slice!(i + 1, delete_count)
          else
            i += 1
          end
        else
          i += 1
        end
      end
    end

    def remove_jump_to_next_label(instructions, spans)
      i = 0
      while i < instructions.length - 1
        inst = instructions[i]
        next_inst = instructions[i + 1]
        if inst[0] == IL::JUMP && next_inst[0] == IL::LABEL && inst[1] == next_inst[1]
          instructions.delete_at(i)
          spans.delete_at(i)
        else
          i += 1
        end
      end
    end

    def merge_raw_writes(instructions, spans)
      i = 0
      while i < instructions.length - 1
        if instructions[i][0] == IL::WRITE_RAW && instructions[i + 1][0] == IL::WRITE_RAW
          # Merge the two writes
          instructions[i] = [IL::WRITE_RAW, instructions[i][1] + instructions[i + 1][1]]
          instructions.delete_at(i + 1)
          spans.delete_at(i + 1)
        else
          i += 1
        end
      end
    end

    def fold_const_captures(instructions, spans)
      i = 0
      while i < instructions.length
        if instructions[i][0] == IL::PUSH_CAPTURE
          pop_idx, const_value = capture_const_body(instructions, i)
          if pop_idx
            assign_idx = pop_idx + 1
            if assign_idx < instructions.length && capture_assignment?(instructions[assign_idx][0])
              const_inst = const_instruction_for(const_value) || [IL::CONST_STRING, const_value]
              instructions[i] = const_inst
              spans[i] = spans[i] || spans[assign_idx]
              delete_count = assign_idx - i - 1
              instructions.slice!(i + 1, delete_count)
              spans.slice!(i + 1, delete_count)
              next
            end
          end
        end
        i += 1
      end
    end

    def capture_assignment?(opcode)
      opcode == IL::ASSIGN || opcode == IL::ASSIGN_LOCAL
    end

    def capture_const_body(instructions, start_idx)
      depth = 1
      idx = start_idx + 1
      const_string = String.new

      while idx < instructions.length
        inst = instructions[idx]
        opcode = inst[0]
        case opcode
        when IL::PUSH_CAPTURE
          return nil if depth == 1
          depth += 1
        when IL::POP_CAPTURE
          depth -= 1
          return [idx, const_string] if depth.zero?
        when IL::WRITE_RAW
          const_string << inst[1] if depth == 1
        when IL::LABEL
          # ignore labels within constant capture bodies
        else
          return nil if depth == 1
        end
        idx += 1
      end

      nil
    end

    def remove_empty_raw_writes(instructions, spans)
      i = 0
      while i < instructions.length
        if instructions[i][0] == IL::WRITE_RAW && instructions[i][1].empty?
          instructions.delete_at(i)
          spans.delete_at(i)
        else
          i += 1
        end
      end
    end

    def remove_unreachable(instructions, spans)
      # Remove instructions after unconditional jumps until we hit a label
      i = 0
      while i < instructions.length - 1
        if instructions[i][0] == IL::JUMP || instructions[i][0] == IL::HALT
          # Check if next instruction is a label
          j = i + 1
          while j < instructions.length && instructions[j][0] != IL::LABEL
            instructions.delete_at(j)
            spans.delete_at(j)
          end
        end
        i += 1
      end
    end

    def inline_partials_enabled?
      !!(@inline_enabled && @partial_loader)
    end

    def lower_const_partials(instructions)
      instructions.each_with_index do |inst, idx|
        opcode = inst[0]
        case opcode
        when IL::CONST_RENDER
          instructions[idx] = lower_const_partial(inst, IL::RENDER_PARTIAL)
        when IL::CONST_INCLUDE
          instructions[idx] = lower_const_partial(inst, IL::INCLUDE_PARTIAL)
        end
      end
    end

    def lower_const_partial(inst, target_opcode)
      name = inst[1]
      args = inst[2].dup
      if inline_partials_enabled? && @partial_loader
        compiled = compile_partial_template(name, @partial_loader)
        args["__compiled_template__"] = compiled if compiled
      end
      [target_opcode, name, args]
    end

    def compile_partial_template(name, loader)
      if (cached = @inline_cache[name])
        return cached
      end

      source = begin
                 loader.read(name)
               rescue StandardError
                 nil
               end
      return nil unless source

      child_stack = @inline_partial_stack + [name]
      child_options = @options.merge(
        inline_partial_stack: child_stack,
        inline_partial_cache: @inline_cache,
        file_system: loader,
        partial_loader: loader
      )
      child_compiler = Compiler.new(source, **child_options)
      result = child_compiler.compile
      compiled = {
        source: source,
        instructions: result[:instructions],
        spans: result[:spans]
      }
      @inline_cache[name] = compiled
      compiled
    end

    SAFE_FOLD_FILTERS = {
      "append" => true,
      "prepend" => true,
      "capitalize" => true,
      "downcase" => true,
      "upcase" => true,
      "size" => true,
      "plus" => true,
      "minus" => true,
      "times" => true,
      "divided_by" => true,
      "modulo" => true,
      "abs" => true,
      "ceil" => true,
      "floor" => true,
      "round" => true,
      "at_least" => true,
      "at_most" => true,
      "strip" => true,
      "lstrip" => true,
      "rstrip" => true,
      "strip_newlines" => true,
      "newline_to_br" => true,
      "escape" => true,
      "escape_once" => true,
      "url_encode" => true,
      "url_decode" => true,
      "remove" => true,
      "remove_first" => true,
      "replace" => true,
      "replace_first" => true,
      "slice" => true,
      "truncate" => true,
      "truncatewords" => true,
      "default" => true,
      "json" => true,
      "t" => true,
      "base64_encode" => true,
      "base64_decode" => true,
      "base64_url_safe_encode" => true,
      "base64_url_safe_decode" => true
    }.freeze

    def const_value(inst)
      case inst[0]
      when IL::CONST_NIL
        [:const, nil]
      when IL::CONST_TRUE
        [:const, true]
      when IL::CONST_FALSE
        [:const, false]
      when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING
        [:const, inst[1]]
      when IL::CONST_RANGE
        [:const, RangeValue.new(inst[1], inst[2])]
      when IL::CONST_EMPTY
        [:const, EmptyLiteral.instance]
      when IL::CONST_BLANK
        [:const, BlankLiteral.instance]
      else
        nil
      end
    end

    def const_instruction_for(value)
      case value
      when nil
        [IL::CONST_NIL]
      when true
        [IL::CONST_TRUE]
      when false
        [IL::CONST_FALSE]
      when Integer
        [IL::CONST_INT, value]
      when Float
        [IL::CONST_FLOAT, value]
      when String
        [IL::CONST_STRING, value]
      when RangeValue
        [IL::CONST_RANGE, value.start_val, value.end_val]
      when EmptyLiteral
        [IL::CONST_EMPTY]
      when BlankLiteral
        [IL::CONST_BLANK]
      else
        nil
      end
    end

    def safe_compare(left, right, op)
      const_evaluator.compare(left, right, op)
    rescue StandardError
      nil
    end

    def safe_case_compare(left, right)
      const_evaluator.case_compare(left, right)
    rescue StandardError
      nil
    end

    def safe_contains(left, right)
      const_evaluator.contains(left, right)
    rescue StandardError
      nil
    end

    def const_evaluator
      @const_evaluator ||= ConstEvaluator.new
    end

    class ConstEvaluator
      def initialize
        @context = Scope.new({})
        @vm = VM.new([], @context)
      end

      def truthy?(value)
        @vm.send(:is_truthy, value)
      end

      def compare(left, right, op)
        @vm.send(:compare, left, right, op)
      end

      def case_compare(left, right)
        @vm.send(:case_compare, left, right)
      end

      def contains(left, right)
        @vm.send(:contains, left, right)
      end

      def filter(name, input, args)
        Filters.apply(name, input, args, @context)
      rescue StandardError
        nil
      end
    end
  end
end
