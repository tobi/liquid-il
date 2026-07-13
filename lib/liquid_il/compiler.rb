# frozen_string_literal: true

module LiquidIL
  # Compiler - wraps parser and provides optimization passes
  class Compiler
    attr_reader :source

    # Opcodes that mark control flow boundaries (used for O(1) lookup)
    CONTROL_FLOW_OPCODES = [
      IL::LABEL, IL::JUMP, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT,
      IL::IF, IL::ELSE, IL::END_IF,
      IL::FOR_INIT, IL::FOR_NEXT, IL::FOR_END, IL::TABLEROW_INIT, IL::TABLEROW_NEXT, IL::TABLEROW_END,
      IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL, IL::HOST_TAG, IL::HALT,
      IL::ASSIGN, IL::ASSIGN_LOCAL,
      IL::INCREMENT, IL::DECREMENT
    ].to_set.freeze

    # Passes handled by fused_peephole (used for conditional dispatch)
    FUSED_PEEPHOLE_PASSES = Passes.resolve(%i[
      fold_const_writes collapse_const_paths
      remove_redundant_is_truthy remove_noops remove_jump_to_next_label
      merge_raw_writes remove_empty_raw_writes propagate_constants fuse_write_var
    ])

    # Opcodes across which constant propagation must forget everything
    # (hash for O(1) per-instruction lookup in the peephole scan)
    PROPAGATION_BARRIERS = [
      IL::LABEL, IL::JUMP, IL::JUMP_IF_INTERRUPT,
      IL::IF, IL::ELSE, IL::END_IF,
      IL::FOR_INIT, IL::FOR_NEXT, IL::FOR_END,
      IL::TABLEROW_INIT, IL::TABLEROW_NEXT, IL::TABLEROW_END,
      IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL, IL::HOST_TAG
    ].each_with_object({}) { |op, h| h[op] = true }.freeze

    def initialize(source, **options)
      @source = source
      @options = options
    end

    def compile
      # Item A: link_and_strip fills these when it runs (it walks the final
      # post-optimization stream — the same stream the hoist census needs — so
      # the census rides along instead of paying a separate full pass). Left
      # false for label-free templates and optimize:false, where the backend
      # falls back to RubyCompiler#compute_hoisted_lookups.
      @hoist_ran = false
      parser = Parser.new(@source,
        # :lax when unspecified — internal callers (statically-compiled
        # partials) parse lax, matching the liquid gem; Compiler::Ruby.compile
        # supplies :strict2 for the main template.
        error_mode: @options[:error_mode] || :lax,
        bug_compatible_whitespace_trimming: @options[:bug_compatible_whitespace_trimming] || false,
        warnings: @options[:warnings]
      )
      instructions = parser.parse
      @warnings = parser.warnings

      lower_const_partials(instructions)

      # Optimization passes run by default; optimize: false opts out
      # (useful for debugging raw parser output).
      optimize_enabled = @options.fetch(:optimize, true)
      if optimize_enabled
        optimize(instructions, skip_passes: @options[:skip_passes])
      end

      # Fuse link + strip_labels when strip_labels is enabled
      # This saves 3 passes over the instruction array (17-20µs for typical templates)
      # Post-melt only loops allocate labels; when the parser allocated none,
      # there is nothing to link or strip — skip the scans entirely.
      if parser.builder.label_counter.zero?
        # no labels or label-jumps in the stream
      elsif optimize_enabled && Passes.enabled.include?(Passes::STRIP_LABELS)
        link_and_strip(instructions)
      else
        IL.link(instructions)
      end

      # Item A: hand link_and_strip's hoisted-lookup census to the Ruby backend
      # so it need not re-walk the whole IL. nil => backend falls back to
      # RubyCompiler#compute_hoisted_lookups.
      hoist = @hoist_ran ? [@hoist_counts, @hoist_written, @hoist_blocked] : nil

      { instructions: instructions, hoist: hoist }
    end

    private

    # Run enabled optimization passes
    # Pass enablement is determined at boot time via LIQUID_PASSES env var
    # See LiquidIL::Passes for configuration options
    def optimize(instructions, skip_passes: nil)
      enabled = Passes.enabled
      # skip_passes may mix pass ids and symbolic names
      enabled = enabled - Passes.resolve(skip_passes) if skip_passes

      # Lazy-initialized max temp index, cached across passes
      @cached_max_temp_index = nil

      # Phase 2: Constant folding (order matters: ops before filters before writes)
      fold_const_ops(instructions) if enabled.include?(Passes::FOLD_CONST_OPS)
      fold_const_filters(instructions) if enabled.include?(Passes::FOLD_CONST_FILTERS)

      # Phase 3: Fused peephole pass — combines passes 3-9, 13, 20 in one scan
      # Each was a separate linear scan; now one pass handles:
      #   - Fold const writes (CONST + WRITE_VALUE → WRITE_RAW)        [pass 3]
      #   - Collapse const paths (LOOKUP_CONST_KEY chains)              [pass 4]
      #   - Remove redundant IS_TRUTHY after boolean ops                [pass 6]
      #   - Remove NOOPs                                                [pass 7]
      #   - Remove jump-to-next-label                                   [pass 8]
      #   - Merge consecutive WRITE_RAW                                 [pass 9]
      #   - Remove empty WRITE_RAW                                      [pass 13]
      #   - Fuse FIND_VAR + WRITE_VALUE → WRITE_VAR                    [pass 20]
      fused_peephole(instructions, enabled) if FUSED_PEEPHOLE_PASSES.intersect?(enabled)

      # Phase 4: Structural passes (need global analysis, can't easily fuse)
      removed = enabled.include?(Passes::REMOVE_UNREACHABLE) && remove_unreachable(instructions)

      # Phase 5: Post-cleanup fused peephole (re-merge after removals = old pass 11);
      # nothing to re-merge when phase 4 removed nothing
      fused_peephole(instructions, enabled) if removed && enabled.include?(Passes::MERGE_RAW_WRITES_2)

      # Phase 6: Constant captures
      captures_folded = enabled.include?(Passes::FOLD_CONST_CAPTURES) && fold_const_captures(instructions)

      # Phase 7: re-fold when new constants appeared — from capture folding
      # (re-run the peephole so its fused propagation sees them) or from
      # propagation substitutions made during the phase-3 peephole itself.
      # Constant propagation runs inside fused_peephole (pass 14).
      if (captures_folded || @peephole_substituted) && enabled.include?(Passes::FOLD_CONST_FILTERS_2)
        fused_peephole(instructions, enabled) if captures_folded
        fold_const_ops(instructions) if enabled.include?(Passes::FOLD_CONST_OPS)
        fold_const_filters(instructions)
        fused_peephole(instructions, enabled)
      end

      # Phase 8: Loop & block-level optimizations
      hoist_loop_invariants(instructions) if enabled.include?(Passes::HOIST_LOOP_INVARIANTS)
      cache_repeated_lookups(instructions) if enabled.include?(Passes::CACHE_REPEATED_LOOKUPS)


      # Phase 10: Final cleanup
      remove_interrupt_checks(instructions) if enabled.include?(Passes::REMOVE_INTERRUPT_CHECKS)

      instructions
    end

    # Fused peephole optimizer — one forward scan handles multiple transforms.
    # Compacts in place with a write cursor: each incoming instruction is
    # matched against the last instruction already written, so every fuse or
    # drop is O(1) instead of an O(n) delete_at. Every pattern consumes at
    # least one instruction, so "changed" is simply "did the array shrink" —
    # callers use the return value to skip redundant re-runs.
    def fused_peephole(instructions, enabled)
      # Pre-compute pass flags to avoid Set#include? per instruction
      p3 = enabled.include?(Passes::FOLD_CONST_WRITES)
      p4 = enabled.include?(Passes::COLLAPSE_CONST_PATHS)
      p6 = enabled.include?(Passes::REMOVE_REDUNDANT_IS_TRUTHY)
      p7 = enabled.include?(Passes::REMOVE_NOOPS)
      p8 = enabled.include?(Passes::REMOVE_JUMP_TO_NEXT_LABEL)
      p9 = enabled.include?(Passes::MERGE_RAW_WRITES)
      p13 = enabled.include?(Passes::REMOVE_EMPTY_RAW_WRITES)
      p14 = enabled.include?(Passes::PROPAGATE_CONSTANTS)
      p20 = enabled.include?(Passes::FUSE_WRITE_VAR)

      len = instructions.length
      w = 0            # instructions[0...w] is the compacted output
      path_at = -1     # index of a LOOKUP_CONST_PATH this scan created (safe to extend)
      merged_at = -1   # index of a WRITE_RAW whose string this scan created (safe to mutate)
      known = p14 ? {} : nil  # var name -> const instruction (straight-line only)
      @peephole_substituted = false
      i = 0
      while i < len
        inst = instructions[i]
        opcode = inst[0]
        i += 1

        # Pass 7 / 13: drop NOOPs and empty WRITE_RAW
        if (p7 && opcode == IL::NOOP) || (p13 && opcode == IL::WRITE_RAW && inst[1].empty?)
          next
        end

        prev = w > 0 ? instructions[w - 1] : nil
        prev_op = prev && prev[0]

        # Pass 14: constant propagation, fused into the same scan. Substituted
        # constants immediately feed the const-folding patterns below.
        # Adjacency is judged on the compacted stream, which is safe: only
        # stack-neutral instructions are ever dropped ahead of an ASSIGN.
        # Fast path: with no constants in flight (the common case), only the
        # ASSIGN check runs per instruction.
        if p14
          if opcode == IL::ASSIGN
            if prev && const_value(prev)
              known[inst[1]] = prev
            else
              known.delete(inst[1])
            end
          elsif !known.empty?
            if opcode == IL::FIND_VAR
              if (const_inst = known[inst[1]])
                inst = const_inst.dup
                opcode = inst[0]
                @peephole_substituted = true
              end
            elsif opcode == IL::ASSIGN_LOCAL || opcode == IL::INCREMENT || opcode == IL::DECREMENT
              known.delete(inst[1])
            elsif PROPAGATION_BARRIERS[opcode]
              # Control flow or partial render — variables could change
              known.clear
            end
          end
        end

        case opcode
        when IL::WRITE_VALUE
          # Pass 20: FIND_VAR(_PATH) + WRITE_VALUE → WRITE_VAR(_PATH).
          # Rewrite the opcode in place: FIND_VAR/WRITE_VAR and
          # FIND_VAR_PATH/WRITE_VAR_PATH have identical operand arity, and
          # operand-carrying instruction arrays are always freshly allocated
          # (only zero-arg opcodes use frozen singletons).
          if p20 && prev_op == IL::FIND_VAR
            prev[0] = IL::WRITE_VAR
            next
          elsif p20 && prev_op == IL::FIND_VAR_PATH
            prev[0] = IL::WRITE_VAR_PATH
            next
          elsif p3 && prev && (cv = const_value(prev))
            # Pass 3: CONST + WRITE_VALUE → WRITE_RAW, cascading into a
            # preceding WRITE_RAW merge (pass 9) or empty-write drop (pass 13)
            raw = Utils.output_string(cv[1])
            if p9 && w > 1 && instructions[w - 2][0] == IL::WRITE_RAW
              instructions[w - 2] = [IL::WRITE_RAW, instructions[w - 2][1] + raw]
              w -= 1
              merged_at = w - 1
            elsif p13 && raw.empty?
              w -= 1
              merged_at = -1
            else
              instructions[w - 1] = [IL::WRITE_RAW, raw]
            end
            next
          end
        when IL::WRITE_RAW
          # Pass 9: merge consecutive WRITE_RAW. The first merge of a run
          # allocates a private string; later merges append in place. Only
          # strings this scan created are mutated (merged_at) — original
          # payloads may be frozen literals or aliased const values.
          if p9 && prev_op == IL::WRITE_RAW
            if merged_at == w - 1
              prev[1] << inst[1]
            else
              instructions[w - 1] = [IL::WRITE_RAW, prev[1] + inst[1]]
              merged_at = w - 1
            end
            next
          end
        when IL::IS_TRUTHY
          # Pass 6: redundant IS_TRUTHY after boolean-producing ops
          if p6 && (prev_op == IL::COMPARE || prev_op == IL::CASE_COMPARE || prev_op == IL::CONTAINS ||
                    prev_op == IL::BOOL_NOT || prev_op == IL::BOOL_AND || prev_op == IL::BOOL_OR)
            next
          end
        when IL::LABEL
          # Pass 8: JUMP directly to the next label — drop the JUMP
          if p8 && prev_op == IL::JUMP && prev[1] == inst[1]
            instructions[w - 1] = inst
            next
          end
        when IL::LOOKUP_CONST_KEY
          # Pass 4: collapse LOOKUP_CONST_KEY chains into LOOKUP_CONST_PATH
          if p4 && prev_op == IL::LOOKUP_CONST_KEY
            instructions[w - 1] = [IL::LOOKUP_CONST_PATH, [prev[1], inst[1]]]
            path_at = w - 1
            next
          elsif p4 && prev_op == IL::LOOKUP_CONST_PATH && path_at == w - 1
            prev[1] << inst[1]
            next
          end
        end

        instructions[w] = inst
        w += 1
      end

      return false if w == len
      instructions.slice!(w, len - w)
      true
    end

    # Fast opcode check for constant instructions (avoids const_value method call overhead)
    CONST_OPCODE_SET = [
      IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING,
      IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_NIL,
      IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK
    ].each_with_object({}) { |op, h| h[op] = true }.freeze

    def fold_const_ops(instructions)
      i = 0
      while i < instructions.length
        inst = instructions[i]
        opcode = inst[0]

        # Fast path: skip non-constant opcodes without calling const_value
        unless CONST_OPCODE_SET[opcode]
          i += 1
          next
        end

        if (const1 = const_value(inst))
          val1 = const1[1]
          # CONST + IS_TRUTHY / BOOL_NOT
          # Truthiness of the empty/blank literals is NOT folded: as standalone
          # conditions they are truthy at runtime (spec-mandated), which
          # disagrees with RuntimeHelpers::IS_TRUTHY — leave them to codegen.
          if i + 1 < instructions.length && (truthy = const_truthiness(val1)) != nil
            next_inst = instructions[i + 1]
            case next_inst[0]
            when IL::IS_TRUTHY
              instructions[i] = truthy ? IL::I_CONST_TRUE : IL::I_CONST_FALSE
              instructions.delete_at(i + 1)
              next
            when IL::BOOL_NOT
              instructions[i] = truthy ? IL::I_CONST_FALSE : IL::I_CONST_TRUE
              instructions.delete_at(i + 1)
              next
            when IL::IF
              # Static branch elimination: the marker structure makes branch
              # extents explicit, so a constant condition selects one branch.
              take_then = next_inst[1] ? !truthy : truthy
              else_idx, end_idx = find_if_branch_bounds(instructions, i + 1)
              if end_idx
                if take_then
                  # Keep then-branch: drop ELSE..END_IF (or just END_IF), then CONST+IF
                  if else_idx
                    count = end_idx - else_idx + 1
                    instructions.slice!(else_idx, count)
                  else
                    instructions.delete_at(end_idx)
                  end
                  instructions.slice!(i, 2)
                else
                  # Keep else-branch (if any): drop END_IF, then CONST..ELSE (or everything)
                  if else_idx
                    instructions.delete_at(end_idx)
                    count = else_idx - i + 1
                    instructions.slice!(i, count)
                  else
                    count = end_idx - i + 1
                    instructions.slice!(i, count)
                  end
                end
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
                  instructions[i] = result ? IL::I_CONST_TRUE : IL::I_CONST_FALSE
                  instructions.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  next
                end
              when IL::CASE_COMPARE
                result = safe_case_compare(val1, val2)
                if result != nil
                  instructions[i] = result ? IL::I_CONST_TRUE : IL::I_CONST_FALSE
                  instructions.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  next
                end
              when IL::CONTAINS
                result = safe_contains(val1, val2)
                if result != nil
                  instructions[i] = result ? IL::I_CONST_TRUE : IL::I_CONST_FALSE
                  instructions.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  next
                end
              when IL::BOOL_AND, IL::BOOL_OR
                l = const_truthiness(val1)
                r = const_truthiness(val2)
                if l != nil && r != nil
                  result = inst3[0] == IL::BOOL_AND ? l && r : l || r
                  instructions[i] = result ? IL::I_CONST_TRUE : IL::I_CONST_FALSE
                  instructions.delete_at(i + 2)
                  instructions.delete_at(i + 1)
                  next
                end
              end
            end
          end
        end

        i += 1
      end
    end

    # Compile-time truthiness, or nil when it cannot be decided statically.
    # EmptyLiteral/BlankLiteral are truthy as standalone conditions but falsy
    # through RuntimeHelpers::IS_TRUTHY, so their truthiness never folds.
    def const_truthiness(value)
      case value
      when EmptyLiteral, BlankLiteral then nil
      else const_evaluator.truthy?(value)
      end
    end

    # Given the index of an IF marker, return [else_idx, end_idx] for its
    # (depth-matched) ELSE and END_IF markers. else_idx is nil when the
    # block has no else branch; both are nil when the block is unterminated.
    def find_if_branch_bounds(instructions, if_idx)
      depth = 0
      else_idx = nil
      i = if_idx + 1
      len = instructions.length
      while i < len
        case instructions[i][0]
        when IL::IF
          depth += 1
        when IL::ELSE
          else_idx = i if depth.zero? && else_idx.nil?
        when IL::END_IF
          return [else_idx, i] if depth.zero?
          depth -= 1
        end
        i += 1
      end
      [nil, nil]
    end

    def fold_const_filters(instructions)
      return if @options[:prefer_custom_filters]

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
                  delete_count = i - first
                  instructions.slice!(first + 1, delete_count)
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

    # Returns true when any capture block was folded.
    def fold_const_captures(instructions)
      changed = false
      i = 0
      while i < instructions.length
        if instructions[i][0] == IL::PUSH_CAPTURE
          pop_idx, const_value = capture_const_body(instructions, i)
          if pop_idx
            assign_idx = pop_idx + 1
            if assign_idx < instructions.length && capture_assignment?(instructions[assign_idx][0])
              const_inst = const_instruction_for(const_value) || [IL::CONST_STRING, const_value]
              instructions[i] = const_inst
              delete_count = assign_idx - i - 1
              instructions.slice!(i + 1, delete_count)
              changed = true
              next
            end
          end
        end
        i += 1
      end
      changed
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

    def remove_empty_raw_writes(instructions)
      i = 0
      while i < instructions.length
        if instructions[i][0] == IL::WRITE_RAW && instructions[i][1].empty?
          instructions.delete_at(i)
        else
          i += 1
        end
      end
    end

    # Loop invariant code motion: hoist invariant variable lookups outside loops
    # Looks for FIND_VAR/FIND_VAR_PATH inside loops that don't depend on loop variables
    def hoist_loop_invariants(instructions)
      # Find all loop ranges (FOR_INIT to FOR_END)
      loops = find_loop_ranges(instructions)
      return if loops.empty?

      # Initialize temp counter for hoisting
      @hoist_temp_counter = max_temp_index(instructions) + 1

      # Process loops from innermost to outermost (reverse order by start index)
      loops.sort_by { |l| -l[:start] }.each do |loop_info|
        hoist_invariants_for_loop(instructions, loop_info)
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

    def hoist_invariants_for_loop(instructions, loop_info)
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
            insertions << [IL::FIND_VAR, var_name]
            insertions << [IL::STORE_TEMP, temp_idx]

            # Replace original with LOAD_TEMP
            instructions[i] = [IL::LOAD_TEMP, temp_idx]
          end
        end

        i += 1
      end

      # Insert hoisted instructions before the loop (before FOR_INIT)
      return if insertions.empty?

      insertions.reverse.each do |inst|
        instructions.insert(start_idx, inst)
        # Adjust end_idx since we inserted before it
        loop_info[:end] += 1
      end
    end

    # Returns true when any instruction was removed.
    def remove_unreachable(instructions)
      # Remove instructions after unconditional jumps until we hit a label
      changed = false
      i = 0
      while i < instructions.length - 1
        if instructions[i][0] == IL::JUMP || instructions[i][0] == IL::HALT
          # Check if next instruction is a label
          j = i + 1
          while j < instructions.length && instructions[j][0] != IL::LABEL
            instructions.delete_at(j)
            changed = true
          end
        end
        i += 1
      end
      changed
    end

    # Strip LABEL instructions after linking and adjust jump targets
    # Labels are only needed during linking - after that they're just no-ops
    # This must run AFTER IL.link since it adjusts absolute instruction indices
    def strip_labels(instructions)
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
        when IL::JUMP, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
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
      end
    end

    # Fused link + strip_labels: combines IL.link and strip_labels into 2 passes
    # instead of 5+ passes, saving 17-20µs for typical templates
    def link_and_strip(instructions)
      # Pass 1: collect label positions (label_id -> index) and, riding along on
      # this same walk of the final stream, the hoisted-lookup census (Item A):
      # read counts per name, the written-name set, and whether hoisting is
      # blocked. This is the exact stream and classification
      # RubyCompiler#compute_hoisted_lookups would re-walk, so no overcount —
      # it just avoids a second full pass. See derive_hoisted_lookups.
      label_positions = {}
      hcounts = Hash.new(0)
      hwritten = nil
      hoist_active = true
      len = instructions.length
      i = 0
      while i < len
        inst = instructions[i]
        opcode = inst[0]
        if opcode == IL::LABEL
          label_positions[inst[1]] = i
        elsif hoist_active
          case opcode
          when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::WRITE_VAR, IL::WRITE_VAR_PATH
            hcounts[inst[1]] += 1
          when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT,
               IL::FOR_INIT, IL::TABLEROW_INIT
            (hwritten ||= {})[inst[1]] = true
          when :PAGINATE_SETUP
            hw = (hwritten ||= {})
            hw["paginate"] = true
            parts = inst[1].to_s.split(".")
            hw[parts.first] = true
            hw[parts.last] = true
          when IL::INCLUDE_PARTIAL, IL::CONST_INCLUDE, :SHOPIFY_SECTION_RENDER
            hoist_active = false
          else
            hoist_active = false unless RubyCompiler::HOIST_NEUTRAL_OPS[opcode]
          end
        end
        i += 1
      end
      @hoist_counts = hcounts
      @hoist_written = hwritten
      @hoist_blocked = !hoist_active
      @hoist_ran = true

      # Quick path: no labels at all
      if label_positions.empty?
        return
      end

      # Build compact label index set for O(1) lookup
      label_idx_set = Set.new
      i = 0
      while i < len
        if instructions[i][0] == IL::LABEL
          label_idx_set << i
        end
        i += 1
      end

      # Build cumulative label count: label_count[i] = labels at indices 0..i-1
      label_count = [0]
      i = 1
      while i < len
        label_count << (label_count[i-1] + (label_idx_set.include?(i-1) ? 1 : 0))
        i += 1
      end
      label_count << label_count.last  # sentinel for boundary

      # Pass 2: build new instructions array, resolving jumps and stripping labels
      new_instructions = []
      i = 0
      while i < len
        inst = instructions[i]
        # Skip label instructions
        if inst[0] == IL::LABEL
          i += 1
          next
        end

        # Resolve and adjust jump targets
        opcode = inst[0]
        if opcode == IL::JUMP || opcode == IL::JUMP_IF_EMPTY || opcode == IL::JUMP_IF_INTERRUPT
          target = label_positions[inst[1]]
          inst[1] = target - label_count[target]
        elsif opcode == IL::FOR_NEXT || opcode == IL::TABLEROW_NEXT
          t1 = label_positions[inst[1]]
          t2 = label_positions[inst[2]]
          inst[1] = t1 - label_count[t1]
          inst[2] = t2 - label_count[t2]
        end

        new_instructions << inst
        i += 1
      end

      instructions.replace(new_instructions)
    end

    # Remove interrupt handling when template never pushes interrupts.
    # This eliminates JUMP_IF_INTERRUPT/POP_INTERRUPT overhead in loops.
    def remove_interrupt_checks(instructions)
      return if interrupt_possible_in_instructions?(instructions)

      i = 0
      while i < instructions.length
        case instructions[i][0]
        when IL::JUMP_IF_INTERRUPT, IL::POP_INTERRUPT
          instructions.delete_at(i)
        else
          i += 1
        end
      end
    end

    def interrupt_possible_in_instructions?(instructions)
      instructions.any? do |inst|
        # Included partials share the caller's scope, so break/continue inside
        # them propagates out — assume interrupts are possible.
        inst[0] == IL::PUSH_INTERRUPT || inst[0] == IL::INCLUDE_PARTIAL || inst[0] == IL::HOST_TAG
      end
    end

    # Cache repeated base object lookups in straight-line code
    # Detects multiple FIND_VAR for same variable and caches first lookup
    def cache_repeated_lookups(instructions)
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
          insertions << [first_idx, temp_idx]
        end

        # Sort by index descending so we can insert without invalidating indices
        insertions.sort_by! { |idx, _| -idx }

        # Apply insertions
        insertions.each do |first_idx, temp_idx|
          # Insert DUP and STORE_TEMP right after FIND_VAR
          instructions.insert(first_idx + 1, [IL::DUP])
          instructions.insert(first_idx + 2, [IL::STORE_TEMP, temp_idx])
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

    # Statically-named partial calls parse as CONST_RENDER/CONST_INCLUDE;
    # lower them to the runtime opcodes. Partial inlining itself is owned by
    # the Ruby backend (RubyCompiler#generate_partial_call).
    def lower_const_partials(instructions)
      instructions.each do |inst|
        case inst[0]
        when IL::CONST_RENDER
          inst[0] = IL::RENDER_PARTIAL
        when IL::CONST_INCLUDE
          inst[0] = IL::INCLUDE_PARTIAL
        end
      end
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
      # Don't fold ordered comparisons between incompatible types —
      # these produce runtime error messages that must be rendered inline.
      if [:lt, :le, :gt, :ge].include?(op) && !comparable_types?(left, right)
        return nil
      end
      const_evaluator.compare(left, right, op)
    rescue StandardError
      nil
    end

    def comparable_types?(left, right)
      return false if left.nil? || right.nil?
      return false if left == true || left == false || right == true || right == false
      (left.is_a?(Numeric) || (left.is_a?(String) && left.match?(/\A-?\d/))) &&
        (right.is_a?(Numeric) || (right.is_a?(String) && right.match?(/\A-?\d/)))
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
      end

      def truthy?(value)
        RuntimeHelpers::IS_TRUTHY.call(value)
      end

      def compare(left, right, op)
        RuntimeHelpers::COMPARE.call(left, right, op)
      end

      def case_compare(left, right)
        left == right
      end

      def contains(left, right)
        RuntimeHelpers::CONTAINS.call(left, right)
      end

      def filter(name, input, args)
        Filters.apply(name, input, args, @context)
      rescue StandardError
        nil
      end
    end
  end
end
