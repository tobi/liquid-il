# frozen_string_literal: true

module LiquidIL
  # Effect analysis for IL instructions
  #
  # Tracks what each instruction reads, writes, and its side effects.
  # Used by optimization passes to safely transform code.
  #
  # Effects tracked:
  # - reads_vars: Set of variable names read from scope
  # - writes_vars: Set of variable names written to scope
  # - reads_stack: Number of stack values consumed
  # - writes_stack: Number of stack values pushed
  # - reads_scope: Depends on scope state (FIND_VAR, etc.)
  # - writes_scope: Modifies scope (PUSH_SCOPE, POP_SCOPE)
  # - produces_output: Writes to output buffer
  # - control_flow: Type of control flow (:jump, :cond_jump, :loop, :halt, nil)
  # - has_side_effects: Filter calls, partials, etc.
  # - barrier: Full optimization barrier (partials, scope changes)
  #
  class EffectAnalysis
    Effect = Struct.new(
      :reads_vars,
      :writes_vars,
      :reads_stack,
      :writes_stack,
      :reads_scope,
      :writes_scope,
      :produces_output,
      :control_flow,
      :has_side_effects,
      :barrier,
      keyword_init: true
    ) do
      def pure?
        !has_side_effects && !produces_output && writes_vars.empty? && !writes_scope && !barrier
      end

      def reads?(var_name)
        reads_vars.include?(var_name)
      end

      def writes?(var_name)
        writes_vars.include?(var_name)
      end

      def hoistable?
        pure? && !reads_scope && control_flow.nil?
      end

      def cacheable?
        pure? && control_flow.nil?
      end
    end

    EMPTY_SET = Set.new.freeze

    def initialize(instructions)
      @instructions = instructions
      @effects = nil
    end

    def effects
      @effects ||= analyze_all
    end

    def [](index)
      effects[index]
    end

    def reads_var?(index, var_name)
      effects[index].reads?(var_name)
    end

    def writes_var?(index, var_name)
      effects[index].writes?(var_name)
    end

    def barrier?(index)
      effects[index].barrier
    end

    def pure?(index)
      effects[index].pure?
    end

    # Find all variables written in a range of instructions
    def written_vars_in_range(start_idx, end_idx)
      result = Set.new
      (start_idx..end_idx).each do |i|
        result.merge(effects[i].writes_vars)
      end
      result
    end

    # Find all variables read in a range of instructions
    def read_vars_in_range(start_idx, end_idx)
      result = Set.new
      (start_idx..end_idx).each do |i|
        result.merge(effects[i].reads_vars)
      end
      result
    end

    # Check if any instruction in range has side effects
    def has_side_effects_in_range?(start_idx, end_idx)
      (start_idx..end_idx).any? { |i| effects[i].has_side_effects }
    end

    # Check if any instruction in range is a barrier
    def has_barrier_in_range?(start_idx, end_idx)
      (start_idx..end_idx).any? { |i| effects[i].barrier }
    end

    private

    def analyze_all
      result = {}
      @instructions.each_with_index do |inst, idx|
        result[idx] = analyze_instruction(inst)
      end
      result
    end

    def analyze_instruction(inst)
      opcode = inst[0]

      case opcode
      # Constants - pure, push 1 value
      when IL::CONST_NIL, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_EMPTY, IL::CONST_BLANK
        pure_push(1)
      when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_RANGE
        pure_push(1)

      # Variable reads - read from scope, push 1 value
      when IL::FIND_VAR
        Effect.new(
          reads_vars: Set[inst[1]],
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 1,
          reads_scope: true,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )
      when IL::FIND_VAR_PATH
        Effect.new(
          reads_vars: Set[inst[1]],
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 1,
          reads_scope: true,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )
      when IL::FIND_VAR_DYNAMIC
        # Pops name from stack, reads unknown var
        Effect.new(
          reads_vars: EMPTY_SET, # Unknown - conservative
          writes_vars: EMPTY_SET,
          reads_stack: 1,
          writes_stack: 1,
          reads_scope: true,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: true # Conservative - unknown var
        )

      # Property lookups - pop object, push result
      when IL::LOOKUP_KEY
        pure_transform(2, 1) # pop key, pop obj, push result
      when IL::LOOKUP_CONST_KEY, IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND
        pure_transform(1, 1) # pop obj, push result

      # Output
      when IL::WRITE_RAW
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: true,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )
      when IL::WRITE_VALUE
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 1,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: true,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Capture - output state management
      when IL::PUSH_CAPTURE
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true, # Changes output target
          barrier: false
        )
      when IL::POP_CAPTURE
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 1, # Pushes captured string
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true, # Changes output target
          barrier: false
        )

      # Control flow
      when IL::LABEL
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: :label,
          has_side_effects: false,
          barrier: false
        )
      when IL::JUMP
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: :jump,
          has_side_effects: false,
          barrier: false
        )
      when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 1,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: :cond_jump,
          has_side_effects: false,
          barrier: false
        )
      when IL::HALT
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: :halt,
          has_side_effects: false,
          barrier: true
        )

      # Comparisons - pure stack transforms
      when IL::COMPARE, IL::CASE_COMPARE, IL::CONTAINS
        pure_transform(2, 1)
      when IL::BOOL_NOT, IL::IS_TRUTHY
        pure_transform(1, 1)

      # Scope management
      when IL::PUSH_SCOPE, IL::POP_SCOPE
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: true,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: true # Scope changes are barriers
        )

      # Assignments
      when IL::ASSIGN, IL::ASSIGN_LOCAL
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: Set[inst[1]],
          reads_stack: 1,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: true,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Range
      when IL::NEW_RANGE
        pure_transform(2, 1)

      # Filter calls
      when IL::CALL_FILTER
        argc = inst[2]
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: argc + 1, # input + args
          writes_stack: 1,
          reads_scope: true, # Filters may access context
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true, # Conservative - custom filters may have effects
          barrier: false
        )

      # Loops
      when IL::FOR_INIT, IL::TABLEROW_INIT
        var_name = inst[1]
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: Set[var_name, "forloop"],
          reads_stack: 1, # Collection
          writes_stack: 0,
          reads_scope: false,
          writes_scope: true,
          produces_output: false,
          control_flow: :loop_init,
          has_side_effects: false,
          barrier: false
        )
      when IL::FOR_NEXT, IL::TABLEROW_NEXT
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET, # Loop var updated implicitly
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: true,
          writes_scope: true,
          produces_output: opcode == IL::TABLEROW_NEXT, # Tablerow outputs HTML
          control_flow: :loop_next,
          has_side_effects: false,
          barrier: false
        )
      when IL::FOR_END, IL::TABLEROW_END
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: true,
          produces_output: opcode == IL::TABLEROW_END, # Tablerow outputs closing tag
          control_flow: :loop_end,
          has_side_effects: false,
          barrier: false
        )
      when IL::PUSH_FORLOOP, IL::POP_FORLOOP
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: true,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Interrupts
      when IL::PUSH_INTERRUPT
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true, # Changes control flow state
          barrier: false
        )
      when IL::POP_INTERRUPT
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: false,
          writes_scope: false,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true,
          barrier: false
        )

      # Counters
      when IL::INCREMENT, IL::DECREMENT
        Effect.new(
          reads_vars: Set[inst[1]],
          writes_vars: Set[inst[1]],
          reads_stack: 0,
          writes_stack: 1, # Pushes new value
          reads_scope: true,
          writes_scope: true,
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Cycle
      when IL::CYCLE_STEP, IL::CYCLE_STEP_VAR
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 1,
          reads_scope: true, # Reads cycle state
          writes_scope: true, # Updates cycle state
          produces_output: false,
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Partials - full barriers
      when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL, IL::CONST_RENDER, IL::CONST_INCLUDE
        Effect.new(
          reads_vars: EMPTY_SET, # Unknown - partial may read anything
          writes_vars: EMPTY_SET, # INCLUDE can write to outer scope
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: true,
          writes_scope: opcode == IL::INCLUDE_PARTIAL || opcode == IL::CONST_INCLUDE,
          produces_output: true,
          control_flow: nil,
          has_side_effects: true,
          barrier: true # Partials are full optimization barriers
        )

      # Stack operations
      when IL::DUP
        pure_transform(1, 2)
      when IL::POP
        pure_transform(1, 0)
      when IL::BUILD_HASH
        count = inst[1]
        pure_transform(count * 2, 1)
      when IL::STORE_TEMP
        pure_transform(1, 0)
      when IL::LOAD_TEMP
        pure_push(1)

      # Ifchanged
      when IL::IFCHANGED_CHECK
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 1,
          writes_stack: 0,
          reads_scope: true, # Reads previous value state
          writes_scope: true, # Updates previous value state
          produces_output: true, # May output captured content
          control_flow: nil,
          has_side_effects: false,
          barrier: false
        )

      # Noop
      when IL::NOOP
        pure_push(0)

      else
        # Unknown instruction - conservative
        Effect.new(
          reads_vars: EMPTY_SET,
          writes_vars: EMPTY_SET,
          reads_stack: 0,
          writes_stack: 0,
          reads_scope: true,
          writes_scope: true,
          produces_output: false,
          control_flow: nil,
          has_side_effects: true,
          barrier: true
        )
      end
    end

    def pure_push(count)
      Effect.new(
        reads_vars: EMPTY_SET,
        writes_vars: EMPTY_SET,
        reads_stack: 0,
        writes_stack: count,
        reads_scope: false,
        writes_scope: false,
        produces_output: false,
        control_flow: nil,
        has_side_effects: false,
        barrier: false
      )
    end

    def pure_transform(pop_count, push_count)
      Effect.new(
        reads_vars: EMPTY_SET,
        writes_vars: EMPTY_SET,
        reads_stack: pop_count,
        writes_stack: push_count,
        reads_scope: false,
        writes_scope: false,
        produces_output: false,
        control_flow: nil,
        has_side_effects: false,
        barrier: false
      )
    end
  end

  # Liveness analysis for temp registers
  #
  # Performs a single backward pass to identify the last-use point for each
  # temp register. This enables register allocation optimizations by knowing
  # when temps become dead and available for reuse.
  #
  # Usage:
  #   liveness = TempLiveness.new(instructions)
  #   liveness.last_use(0)  # => instruction index of last LOADTEMP for temp 0
  #   liveness.dead_after?(0, 5)  # => true if temp 0 is dead after instruction 5
  #
  class TempLiveness
    # Analyze temp register liveness for an instruction sequence
    #
    # @param instructions [Array] IL instruction array
    def initialize(instructions)
      @instructions = instructions
      @last_use = nil  # temp_index => last instruction index where it's used
    end

    # Returns the instruction index where the temp is last used (LOAD_TEMP)
    # Returns nil if the temp is never used
    #
    # @param temp_index [Integer] the temp register index
    # @return [Integer, nil] the last-use instruction index
    def last_use(temp_index)
      analyze unless @last_use
      @last_use[temp_index]
    end

    # Returns the mapping of all temp indices to their last-use instruction indices
    #
    # @return [Hash<Integer, Integer>] temp_index => last_use_index
    def last_use_map
      analyze unless @last_use
      @last_use
    end

    # Checks if a temp register is dead (no more uses) after the given instruction
    #
    # @param temp_index [Integer] the temp register index
    # @param instruction_index [Integer] the instruction index to check
    # @return [Boolean] true if the temp has no uses after this instruction
    def dead_after?(temp_index, instruction_index)
      analyze unless @last_use
      last = @last_use[temp_index]
      return true if last.nil?  # Never used, so always dead
      instruction_index >= last
    end

    # Returns all temps that are live (have future uses) at a given instruction
    #
    # @param instruction_index [Integer] the instruction index to check
    # @return [Array<Integer>] temp indices that are still live
    def live_at(instruction_index)
      analyze unless @last_use
      @last_use.select { |_temp, last| last > instruction_index }.keys
    end

    private

    # Single backward pass to find last-use point for each temp
    def analyze
      @last_use = {}

      # Scan backward through instructions
      # The first LOAD_TEMP we encounter (going backward) is the last use
      (@instructions.length - 1).downto(0) do |i|
        inst = @instructions[i]
        opcode = inst[0]

        case opcode
        when IL::LOAD_TEMP
          temp_index = inst[1]
          # Only record if we haven't seen this temp yet (first encounter going backward = last use)
          @last_use[temp_index] ||= i

        when IL::STORE_TEMP
          # STORE_TEMP is a definition, not a use
          # We track it here to ensure the temp exists in our map even if never loaded
          temp_index = inst[1]
          @last_use[temp_index] ||= nil  # Mark as defined but potentially unused
        end
      end

      # Remove entries where temp was defined but never used (value is nil)
      @last_use.delete_if { |_, v| v.nil? }

      @last_use
    end
  end

  # Register allocation optimization pass
  #
  # Combines backward liveness analysis with forward allocation to minimize
  # peak temp register usage. Follows the optimization pass pattern with an
  # optimize(ir) class method that returns optimized IR.
  #
  # Usage:
  #   optimized_ir = RegisterAllocator.optimize(instructions)
  #
  class RegisterAllocator
    # Optimization pass entry point - analyzes and rewrites temp indices
    #
    # @param ir [Array] IL instruction array
    # @return [Array] optimized instruction array with minimized temp indices
    def self.optimize(ir)
      allocator = TempAllocator.new(ir)
      allocator.allocate!
    end
  end

  # Forward pass temp register allocator
  #
  # Rewrites STORE_TEMP/LOAD_TEMP indices to minimize peak register usage by
  # reusing temp slots that become dead. Uses liveness analysis to identify
  # when temps are no longer needed.
  #
  # Usage:
  #   allocator = TempAllocator.new(instructions)
  #   allocator.allocate!  # Modifies instructions in place
  #   allocator.peak_usage  # => maximum number of live temps at any point
  #
  class TempAllocator
    attr_reader :peak_usage

    # @param instructions [Array] IL instruction array to rewrite
    def initialize(instructions)
      @instructions = instructions
      @liveness = TempLiveness.new(instructions)
      @peak_usage = 0
    end

    # Rewrites temp indices in place to minimize peak register usage
    # @return [Array] the modified instructions array
    def allocate!
      last_use_map = @liveness.last_use_map
      return @instructions if last_use_map.empty?

      # Mapping from original temp index to allocated slot
      temp_to_slot = {}

      # Pool of available (dead) slots, sorted for deterministic allocation
      available_slots = []

      # Next fresh slot to allocate when pool is empty
      next_slot = 0

      # Track currently live slots for peak calculation
      live_slots = Set.new

      @instructions.each_with_index do |inst, i|
        opcode = inst[0]

        case opcode
        when IL::STORE_TEMP
          original_temp = inst[1]

          # Check if this temp already has an allocated slot (re-definition)
          # This can happen with control flow (e.g., case/when setting a flag)
          # In that case, keep using the same slot to preserve correctness
          slot = temp_to_slot[original_temp]

          unless slot
            # First definition - allocate a new slot
            slot = if available_slots.any?
                     available_slots.shift
                   else
                     s = next_slot
                     next_slot += 1
                     s
                   end
            temp_to_slot[original_temp] = slot
          end

          live_slots << slot
          @peak_usage = [live_slots.size, @peak_usage].max

          # Rewrite the instruction
          inst[1] = slot

        when IL::LOAD_TEMP
          original_temp = inst[1]
          slot = temp_to_slot[original_temp]

          # Rewrite the instruction
          inst[1] = slot if slot

          # Check if this is the last use - if so, return slot to pool
          if last_use_map[original_temp] == i
            live_slots.delete(slot)
            # Insert in sorted order for deterministic allocation
            insert_idx = available_slots.bsearch_index { |s| s > slot } || available_slots.size
            available_slots.insert(insert_idx, slot)
          end
        end
      end

      @instructions
    end
  end
end
