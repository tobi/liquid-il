# frozen_string_literal: true

module LiquidIL
  # Compiler - wraps parser and provides optimization passes
  class Compiler
    attr_reader :source

    # Opcodes that mark control flow boundaries (used for O(1) lookup)
    CONTROL_FLOW_OPCODES = [
      IL::LABEL, IL::JUMP, IL::JUMP_IF_TRUE, IL::JUMP_IF_FALSE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT,
      IL::FOR_INIT, IL::FOR_NEXT, IL::FOR_END, IL::TABLEROW_INIT, IL::TABLEROW_NEXT, IL::TABLEROW_END,
      IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL, IL::HALT,
      IL::ASSIGN, IL::ASSIGN_LOCAL,
      IL::INCREMENT, IL::DECREMENT
    ].to_set.freeze

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

      # Optimization pass 21: Strip labels after linking (VM speedup)
      # Must run after IL.link since it adjusts jump target indices
      if @options[:optimize] && Passes.enabled.include?(21)
        strip_labels(instructions, spans)
      end

      { instructions: instructions, spans: spans }
    end

    private

    # Run enabled optimization passes
    # Pass enablement is determined at boot time via LIQUID_PASSES env var
    # See LiquidIL::Passes for configuration options
    def optimize(instructions, spans)
      enabled = Passes.enabled

      # Lazy-initialized max temp index, cached across passes
      @cached_max_temp_index = nil

      # Optimization pass 0: Inline simple partials (enables cross-template optimizations)
      inline_simple_partials(instructions, spans) if enabled.include?(0)

      # Optimization pass 1: Fold constant operations
      fold_const_ops(instructions, spans) if enabled.include?(1)

      # Optimization pass 2: Fold constant filters
      fold_const_filters(instructions, spans) if enabled.include?(2)

      # Optimization pass 3: Fold constant output writes
      fold_const_writes(instructions, spans) if enabled.include?(3)

      # Optimization pass 4: Collapse chained constant lookups
      collapse_const_paths(instructions, spans) if enabled.include?(4)

      # Optimization pass 5: Collapse FIND_VAR + LOOKUP_CONST_PATH
      collapse_find_var_paths(instructions, spans) if enabled.include?(5)

      # Optimization pass 6: Remove redundant IS_TRUTHY on boolean ops
      remove_redundant_is_truthy(instructions, spans) if enabled.include?(6)

      # Optimization pass 7: Remove no-ops
      remove_noops(instructions, spans) if enabled.include?(7)

      # Optimization pass 8: Remove jumps to the immediately following label
      remove_jump_to_next_label(instructions, spans) if enabled.include?(8)

      # Optimization pass 9: Merge consecutive WRITE_RAW
      merge_raw_writes(instructions, spans) if enabled.include?(9)

      # Optimization pass 10: Remove unreachable code after unconditional jumps
      remove_unreachable(instructions, spans) if enabled.include?(10)

      # Optimization pass 11: Re-merge WRITE_RAW after other removals
      merge_raw_writes(instructions, spans) if enabled.include?(11)

      # Optimization pass 12: Fold constant capture blocks into direct assigns
      fold_const_captures(instructions, spans) if enabled.include?(12)

      # Optimization pass 13: Remove empty WRITE_RAW (no observable output)
      remove_empty_raw_writes(instructions, spans) if enabled.include?(13)

      # Optimization pass 14: Constant propagation - replace FIND_VAR with known constants
      propagate_constants(instructions, spans) if enabled.include?(14)

      # Optimization pass 15: Re-run constant folding after propagation
      if enabled.include?(15)
        fold_const_filters(instructions, spans)
        fold_const_writes(instructions, spans)
        merge_raw_writes(instructions, spans)
      end

      # Optimization pass 16: Loop invariant code motion - hoist invariant lookups outside loops
      hoist_loop_invariants(instructions, spans) if enabled.include?(16)

      # Optimization pass 17: Cache repeated base object lookups in straight-line code
      cache_repeated_lookups(instructions, spans) if enabled.include?(17)

      # Optimization pass 18: Local value numbering - eliminate redundant computations
      value_numbering(instructions, spans) if enabled.include?(18)

      # Optimization pass 19: Temp register allocation - reuse dead temp slots
      RegisterAllocator.optimize(instructions) if enabled.include?(19)

      # Optimization pass 20: Fuse FIND_VAR + WRITE_VALUE -> WRITE_VAR (VM speedup)
      fuse_write_var(instructions, spans) if enabled.include?(20)

      # Optimization pass 22: Remove interrupt checks when no break/continue exists
      remove_interrupt_checks(instructions, spans) if enabled.include?(22)

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

    # Loop invariant code motion: hoist invariant variable lookups outside loops
    # Looks for FIND_VAR/FIND_VAR_PATH inside loops that don't depend on loop variables
    def hoist_loop_invariants(instructions, spans)
      # Find all loop ranges (FOR_INIT to FOR_END)
      loops = find_loop_ranges(instructions)
      return if loops.empty?

      # Initialize temp counter for hoisting
      @hoist_temp_counter = max_temp_index(instructions) + 1

      # Process loops from innermost to outermost (reverse order by start index)
      loops.sort_by { |l| -l[:start] }.each do |loop_info|
        hoist_invariants_for_loop(instructions, spans, loop_info)
      end
    end

    # Get max temp index used in instructions (cached for efficiency)
    # First call scans instructions; subsequent calls return cached value
    def max_temp_index(instructions)
      return @cached_max_temp_index if @cached_max_temp_index

      max_idx = -1
      instructions.each do |inst|
        case inst[0]
        when IL::STORE_TEMP, IL::LOAD_TEMP
          max_idx = [max_idx, inst[1]].max
        end
      end
      @cached_max_temp_index = max_idx
    end

    # Allocate a new temp index (increments cached max and returns it)
    def allocate_temp_index(instructions)
      max_temp_index(instructions) # ensure cache is populated
      @cached_max_temp_index += 1
    end

    def find_loop_ranges(instructions)
      loops = []
      stack = []

      instructions.each_with_index do |inst, i|
        case inst[0]
        when IL::FOR_INIT, IL::TABLEROW_INIT
          # Push loop start - loop var is inst[1]
          stack.push({ start: i, loop_var: inst[1], type: inst[0] })
        when IL::FOR_END, IL::TABLEROW_END
          if stack.any?
            loop_info = stack.pop
            loop_info[:end] = i
            loops << loop_info
          end
        end
      end

      loops
    end

    def hoist_invariants_for_loop(instructions, spans, loop_info)
      start_idx = loop_info[:start]
      end_idx = loop_info[:end]
      loop_var = loop_info[:loop_var]

      # Find all variables written inside the loop
      written_vars = Set.new([loop_var, "forloop", "tablerowloop"])
      (start_idx..end_idx).each do |i|
        inst = instructions[i]
        case inst[0]
        when IL::ASSIGN, IL::ASSIGN_LOCAL
          written_vars << inst[1]
        when IL::INCREMENT, IL::DECREMENT
          written_vars << inst[1]
        end
      end

      # Find hoistable FIND_VAR instructions (not referencing written vars)
      # and track which we've already hoisted to avoid duplicates
      hoisted = {}  # var_name -> temp_index
      insertions = []  # [instruction, span] pairs to insert before loop

      i = start_idx + 1  # Start after FOR_INIT
      while i < end_idx
        inst = instructions[i]

        if inst[0] == IL::FIND_VAR && !written_vars.include?(inst[1])
          var_name = inst[1]

          if hoisted.key?(var_name)
            # Already hoisted - replace with LOAD_TEMP
            instructions[i] = [IL::LOAD_TEMP, hoisted[var_name]]
          else
            # First occurrence - hoist and replace
            # Use global counter to avoid conflicts with nested loops
            temp_idx = @hoist_temp_counter
            @hoist_temp_counter += 1
            hoisted[var_name] = temp_idx

            # Add hoisted instruction before loop
            insertions << [[IL::FIND_VAR, var_name], spans[i]]
            insertions << [[IL::STORE_TEMP, temp_idx], spans[i]]

            # Replace original with LOAD_TEMP
            instructions[i] = [IL::LOAD_TEMP, temp_idx]
          end
        end

        i += 1
      end

      # Insert hoisted instructions before the loop (before FOR_INIT)
      return if insertions.empty?

      insertions.reverse.each do |inst, span|
        instructions.insert(start_idx, inst)
        spans.insert(start_idx, span)
        # Adjust end_idx since we inserted before it
        loop_info[:end] += 1
      end
    end

    # Constant propagation: replace FIND_VAR with known constant values
    # Only propagates in straight-line code (invalidates at control flow)
    def propagate_constants(instructions, spans)
      # Map of variable name -> [const_instruction, span]
      known_constants = {}

      i = 0
      while i < instructions.length
        inst = instructions[i]
        opcode = inst[0]

        case opcode
        when IL::CONST_NIL, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING
          # Check if next instruction is ASSIGN
          if i + 1 < instructions.length && instructions[i + 1][0] == IL::ASSIGN
            var_name = instructions[i + 1][1]
            known_constants[var_name] = [inst.dup, spans[i]]
          end

        when IL::ASSIGN, IL::ASSIGN_LOCAL
          # Variable is being reassigned - if not from a constant we just saw, invalidate
          var_name = inst[1]
          # Check if previous was a constant (already handled above)
          prev = i > 0 ? instructions[i - 1] : nil
          unless prev && const_value(prev)
            known_constants.delete(var_name)
          end

        when IL::FIND_VAR
          # Replace with known constant if available
          var_name = inst[1]
          if (const_info = known_constants[var_name])
            const_inst, const_span = const_info
            instructions[i] = const_inst.dup
            # Keep original span for error reporting
          end

        when IL::LABEL, IL::JUMP, IL::JUMP_IF_TRUE, IL::JUMP_IF_FALSE, IL::JUMP_IF_INTERRUPT,
             IL::FOR_INIT, IL::FOR_NEXT, IL::FOR_END, IL::TABLEROW_INIT, IL::TABLEROW_NEXT, IL::TABLEROW_END,
             IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          # Control flow or partial render - invalidate all known constants
          # (Variables could be modified in loops, branches, or partials)
          known_constants.clear

        when IL::INCREMENT, IL::DECREMENT
          # These create/modify variables
          known_constants.delete(inst[1])
        end

        i += 1
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

    # Fuse FIND_VAR + WRITE_VALUE into WRITE_VAR (and FIND_VAR_PATH + WRITE_VALUE into WRITE_VAR_PATH)
    # This is a VM optimization that eliminates stack operations for simple variable output
    def fuse_write_var(instructions, spans)
      i = 0
      while i < instructions.length - 1
        inst = instructions[i]
        next_inst = instructions[i + 1]

        if next_inst[0] == IL::WRITE_VALUE
          case inst[0]
          when IL::FIND_VAR
            # Fuse FIND_VAR + WRITE_VALUE -> WRITE_VAR
            instructions[i] = [IL::WRITE_VAR, inst[1]]
            spans[i] = spans[i + 1] || spans[i]
            instructions.delete_at(i + 1)
            spans.delete_at(i + 1)
            next
          when IL::FIND_VAR_PATH
            # Fuse FIND_VAR_PATH + WRITE_VALUE -> WRITE_VAR_PATH
            instructions[i] = [IL::WRITE_VAR_PATH, inst[1], inst[2]]
            spans[i] = spans[i + 1] || spans[i]
            instructions.delete_at(i + 1)
            spans.delete_at(i + 1)
            next
          end
        end

        i += 1
      end
    end

    # Strip LABEL instructions after linking and adjust jump targets
    # Labels are only needed during linking - after that they're just no-ops
    # This must run AFTER IL.link since it adjusts absolute instruction indices
    def strip_labels(instructions, spans)
      # Build a map of old index -> new index (accounting for removed labels)
      label_indices = []
      instructions.each_with_index do |inst, idx|
        label_indices << idx if inst[0] == IL::LABEL
      end

      return if label_indices.empty?

      # Build index adjustment map: for each original index, how many labels
      # were removed before it (not including labels AT the index)
      adjustment = Array.new(instructions.length, 0)
      removed_count = 0
      label_set = label_indices.to_set

      instructions.length.times do |idx|
        adjustment[idx] = removed_count
        if label_set.include?(idx)
          removed_count += 1
        end
      end

      # Adjust all jump targets
      instructions.each do |inst|
        case inst[0]
        when IL::JUMP, IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
          target = inst[1]
          inst[1] = target - adjustment[target] if target < adjustment.length
        when IL::FOR_NEXT, IL::TABLEROW_NEXT
          target1 = inst[1]
          target2 = inst[2]
          inst[1] = target1 - adjustment[target1] if target1 < adjustment.length
          inst[2] = target2 - adjustment[target2] if target2 < adjustment.length
        end
      end

      # Remove label instructions (in reverse order to maintain indices)
      label_indices.reverse.each do |idx|
        instructions.delete_at(idx)
        spans.delete_at(idx)
      end
    end

    # Remove interrupt handling when template never pushes interrupts.
    # This eliminates JUMP_IF_INTERRUPT/POP_INTERRUPT overhead in loops.
    def remove_interrupt_checks(instructions, spans)
      return if interrupt_possible_in_instructions?(instructions)

      i = 0
      while i < instructions.length
        case instructions[i][0]
        when IL::JUMP_IF_INTERRUPT, IL::POP_INTERRUPT
          instructions.delete_at(i)
          spans.delete_at(i)
        else
          i += 1
        end
      end
    end

    def interrupt_possible_in_instructions?(instructions, visited = {})
      key = instructions.object_id
      return false if visited[key]
      visited[key] = true

      instructions.each do |inst|
        case inst[0]
        when IL::PUSH_INTERRUPT
          return true
        when IL::INCLUDE_PARTIAL
          args = inst[2] || {}
          compiled = args["__compiled_template__"]
          return true unless compiled
          return true if interrupt_possible_in_instructions?(compiled[:instructions], visited)
        end
      end

      false
    end

    # Cache repeated base object lookups in straight-line code
    # Detects multiple FIND_VAR for same variable and caches first lookup
    def cache_repeated_lookups(instructions, spans)
      # Find max temp index already in use
      temp_counter = find_max_temp_index(instructions) + 1

      # Find basic blocks (segments between control flow boundaries)
      blocks = find_straight_line_blocks(instructions)

      # Process each block
      blocks.each do |block_start, block_end|
        # Count FIND_VAR occurrences for each variable in this block
        var_counts = Hash.new(0)
        var_first_idx = {}

        (block_start..block_end).each do |i|
          inst = instructions[i]
          if inst[0] == IL::FIND_VAR
            var_name = inst[1]
            var_counts[var_name] += 1
            var_first_idx[var_name] ||= i
          end
        end

        # Cache variables that appear 2+ times
        cached = {}  # var_name -> temp_index
        insertions = []  # [[index, [instructions]], ...]

        var_counts.each do |var_name, count|
          next if count < 2

          first_idx = var_first_idx[var_name]
          temp_idx = temp_counter
          temp_counter += 1
          cached[var_name] = temp_idx

          # Insert DUP + STORE_TEMP immediately after first FIND_VAR
          # These must stay together, so we store them as a pair
          insertions << [first_idx, temp_idx, spans[first_idx]]
        end

        # Sort by index descending so we can insert without invalidating indices
        insertions.sort_by! { |idx, _, _| -idx }

        # Apply insertions
        insertions.each do |first_idx, temp_idx, span|
          # Insert DUP and STORE_TEMP right after FIND_VAR
          instructions.insert(first_idx + 1, [IL::DUP])
          spans.insert(first_idx + 1, span)
          instructions.insert(first_idx + 2, [IL::STORE_TEMP, temp_idx])
          spans.insert(first_idx + 2, span)
        end

        # Now replace subsequent FIND_VAR with LOAD_TEMP
        # Need to rescan since indices changed
        next if cached.empty?

        seen = Hash.new(0)  # track how many times we've seen each var
        i = block_start
        while i < instructions.length
          inst = instructions[i]
          break if control_flow_boundary?(inst)  # past block end

          if inst[0] == IL::FIND_VAR
            var_name = inst[1]
            if (temp_idx = cached[var_name])
              seen[var_name] += 1
              if seen[var_name] > 1
                # Replace with LOAD_TEMP
                instructions[i] = [IL::LOAD_TEMP, temp_idx]
              end
            end
          end
          i += 1
        end
      end
    end

    def find_straight_line_blocks(instructions)
      blocks = []
      block_start = 0

      instructions.each_with_index do |inst, i|
        if control_flow_boundary?(inst)
          blocks << [block_start, i - 1] if i > block_start
          block_start = i + 1
        end
      end

      # Add final block
      blocks << [block_start, instructions.length - 1] if block_start < instructions.length

      blocks
    end

    def control_flow_boundary?(inst)
      CONTROL_FLOW_OPCODES.include?(inst[0])
    end

    # Find the maximum temp index used in the instructions
    def find_max_temp_index(instructions)
      max_idx = -1
      instructions.each do |inst|
        case inst[0]
        when IL::STORE_TEMP, IL::LOAD_TEMP
          max_idx = [max_idx, inst[1]].max
        end
      end
      max_idx
    end

    # Local value numbering: eliminate redundant computations within basic blocks
    # Assigns value numbers to expressions and reuses cached results when the same
    # computation is performed again.
    def value_numbering(instructions, spans)
      temp_counter = find_max_temp_index(instructions) + 1
      blocks = find_straight_line_blocks(instructions)

      blocks.each do |block_start, block_end|
        # value_number_block returns updated temp_counter - no need to rescan
        temp_counter = value_number_block(instructions, spans, block_start, block_end, temp_counter)
      end
    end

    def value_number_block(instructions, spans, block_start, block_end, temp_counter)
      # Map from value expression -> { temp_index:, first_idx: }
      # Value expressions are canonical representations of computations
      value_table = {}

      # Track which variables have been modified in this block
      modified_vars = Set.new

      # First pass: identify repeated expressions and assign temp slots
      insertions = []  # [[after_idx, temp_idx, span], ...]

      i = block_start
      while i <= block_end
        inst = instructions[i]
        opcode = inst[0]

        # Get value expression for this instruction BEFORE marking modifications
        # This way the current lookup can still be cached before the modification
        expr_key = value_expression_key(inst, modified_vars)

        if expr_key
          if (existing = value_table[expr_key])
            # Already computed - mark for replacement
            # Don't do anything here, we'll handle in second pass
          else
            # First occurrence - check if it appears again in the block
            # without intervening modifications
            appears_again = false
            lookahead_modified = modified_vars.dup
            j = i + 1
            while j <= block_end
              other_inst = instructions[j]

              # Check for modifications BEFORE checking the expression
              case other_inst[0]
              when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT
                var_name = other_inst[1]
                # If this modification affects our expression, stop looking
                if expr_key.start_with?("var:#{var_name}") &&
                   (expr_key == "var:#{var_name}" || expr_key.start_with?("var:#{var_name}:"))
                  break
                end
                lookahead_modified << var_name
              end

              other_key = value_expression_key(other_inst, lookahead_modified)
              if other_key == expr_key
                appears_again = true
                break
              end
              j += 1
            end

            if appears_again
              # Cache this value
              value_table[expr_key] = { temp_index: temp_counter, first_idx: i }
              insertions << [i, temp_counter, spans[i]]
              temp_counter += 1
            end
          end
        end

        # Mark modifications AFTER processing the instruction
        case opcode
        when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT
          modified_vars << inst[1]
          # Invalidate any cached values for this variable
          value_table.delete_if { |k, _| k.start_with?("var:#{inst[1]}") && (k == "var:#{inst[1]}" || k.start_with?("var:#{inst[1]}:")) }
        end

        i += 1
      end

      # Apply insertions (DUP + STORE_TEMP after first occurrence)
      # Process in reverse order to maintain indices
      insertions.sort_by! { |idx, _, _| -idx }
      insertions.each do |after_idx, temp_idx, span|
        instructions.insert(after_idx + 1, [IL::DUP])
        spans.insert(after_idx + 1, span)
        instructions.insert(after_idx + 2, [IL::STORE_TEMP, temp_idx])
        spans.insert(after_idx + 2, span)
      end

      # Recalculate block boundaries after insertions
      return if insertions.empty?

      # Second pass: replace subsequent occurrences with LOAD_TEMP
      # Rebuild value table with updated indices
      value_table_updated = {}
      modified_vars.clear

      i = block_start
      while i < instructions.length
        inst = instructions[i]
        break if control_flow_boundary?(inst)

        opcode = inst[0]

        case opcode
        when IL::STORE_TEMP
          # Find the value expression for the instruction before DUP
          if i >= 2 && instructions[i - 1][0] == IL::DUP
            prev_inst = instructions[i - 2]
            expr_key = value_expression_key(prev_inst, modified_vars)
            if expr_key
              value_table_updated[expr_key] = inst[1]  # temp index
            end
          end
        when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT
          # Invalidate cached value for this variable
          var_name = inst[1]
          value_table_updated.delete_if { |k, _| k.start_with?("var:#{var_name}") && (k == "var:#{var_name}" || k.start_with?("var:#{var_name}:")) }
          modified_vars << var_name
        else
          expr_key = value_expression_key(inst, modified_vars)
          if expr_key && (temp_idx = value_table_updated[expr_key])
            # Replace with LOAD_TEMP
            instructions[i] = [IL::LOAD_TEMP, temp_idx]
          end
        end

        i += 1
      end

      temp_counter  # Return updated temp_counter for next block
    end

    # Inline simple partials: Replace RENDER_PARTIAL/INCLUDE_PARTIAL with inlined instructions
    # Only inlines partials with:
    # - Statically known name (has __compiled_template__)
    # - No with/for modifiers
    # - Simple constant arguments only
    #
    # For RENDER_PARTIAL: wraps with PUSH_SCOPE/POP_SCOPE (isolated scope)
    # For INCLUDE_PARTIAL: no scope wrapper (shares caller's scope, interrupts propagate naturally)
    def inline_simple_partials(instructions, spans)
      i = 0
      while i < instructions.length
        inst = instructions[i]
        opcode = inst[0]

        if opcode == IL::RENDER_PARTIAL || opcode == IL::INCLUDE_PARTIAL
          args = inst[2]
          compiled = args["__compiled_template__"]

          # Only inline if we have pre-compiled template and no complex modifiers
          if compiled && can_inline_partial?(args)
            partial_instructions = compiled[:instructions]
            partial_spans = compiled[:spans]

            # Build replacement instruction sequence
            replacement = []
            replacement_spans = []

            # Get partial name and source for context tracking
            partial_name = inst[1]
            partial_source = compiled[:source]

            # For render: push isolated scope
            if opcode == IL::RENDER_PARTIAL
              replacement << [IL::PUSH_SCOPE]
              replacement_spans << spans[i]
            end

            # Set context to partial for error reporting
            replacement << [IL::SET_CONTEXT, partial_name, partial_source]
            replacement_spans << spans[i]

            # Add argument assignments (constant args only)
            args.each do |key, value|
              next if key.start_with?("__")
              replacement << [IL::CONST_STRING, value.to_s] if value.is_a?(String)
              replacement << [IL::CONST_INT, value] if value.is_a?(Integer)
              replacement << [IL::CONST_FLOAT, value] if value.is_a?(Float)
              replacement << [IL::CONST_TRUE] if value == true
              replacement << [IL::CONST_FALSE] if value == false
              replacement << [IL::CONST_NIL] if value.nil?
              next unless replacement.last # skip non-constant args
              replacement << [IL::ASSIGN_LOCAL, key]
              replacement_spans << spans[i]
              replacement_spans << spans[i]
            end

            # Add partial instructions (skip final HALT)
            partial_instructions.each_with_index do |partial_inst, j|
              next if partial_inst[0] == IL::HALT
              replacement << partial_inst.dup
              replacement_spans << (partial_spans[j] || spans[i])
            end

            # Restore context to nil (main template)
            replacement << [IL::SET_CONTEXT, nil, nil]
            replacement_spans << spans[i]

            # For render: pop scope
            if opcode == IL::RENDER_PARTIAL
              replacement << [IL::POP_SCOPE]
              replacement_spans << spans[i]
            end

            # Replace the RENDER_PARTIAL/INCLUDE_PARTIAL with inlined sequence
            instructions.slice!(i, 1)
            spans.slice!(i, 1)
            instructions.insert(i, *replacement)
            spans.insert(i, *replacement_spans)

            # Don't increment i - process the newly inserted instructions
            next
          end
        end

        i += 1
      end
    end

    def can_inline_partial?(args)
      # Don't inline if there are complex modifiers
      return false if args["__with__"]
      return false if args["__for__"]
      return false if args["__dynamic_name__"]
      return false if args["__invalid_name__"]

      # Only inline if all arguments are simple constants
      args.each do |key, value|
        next if key.start_with?("__")
        # Allow simple constant types only
        case value
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          # OK
        else
          return false # Complex argument (hash, variable lookup, etc.)
        end
      end

      true
    end

    # Generate a canonical key for a value-producing instruction
    # Returns nil for instructions that shouldn't be cached
    #
    # NOTE: FIND_VAR and FIND_VAR_PATH are intentionally NOT cached because
    # the VM's hash lookups are faster than DUP/STORE_TEMP/LOAD_TEMP overhead.
    # This pass is reserved for expensive operations like certain filter calls.
    #
    # Future candidates for caching:
    # - Expensive pure filter calls (e.g., json, sort on large arrays)
    # - Complex computed properties on drops
    def value_expression_key(_inst, _modified_vars)
      # Currently returns nil for all instructions - the infrastructure exists
      # for future use with expensive operations where caching pays off
      nil
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
