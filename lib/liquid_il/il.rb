# frozen_string_literal: true

module LiquidIL
  # IL Instruction definitions
  # All instructions are simple arrays for minimal allocation
  # Format: [:OPCODE, arg1, arg2, ...]
  module IL
    # Output opcodes
    WRITE_RAW = :WRITE_RAW           # [:WRITE_RAW, string]
    WRITE_VALUE = :WRITE_VALUE       # [:WRITE_VALUE]
    WRITE_VAR = :WRITE_VAR           # [:WRITE_VAR, name] - fused FIND_VAR + WRITE_VALUE
    WRITE_VAR_PATH = :WRITE_VAR_PATH # [:WRITE_VAR_PATH, name, [path]] - fused FIND_VAR_PATH + WRITE_VALUE

    # Constant opcodes (no lookup needed)
    CONST_NIL = :CONST_NIL           # [:CONST_NIL]
    CONST_TRUE = :CONST_TRUE         # [:CONST_TRUE]
    CONST_FALSE = :CONST_FALSE       # [:CONST_FALSE]
    CONST_INT = :CONST_INT           # [:CONST_INT, value]
    CONST_FLOAT = :CONST_FLOAT       # [:CONST_FLOAT, value]
    CONST_STRING = :CONST_STRING     # [:CONST_STRING, value]
    CONST_RANGE = :CONST_RANGE       # [:CONST_RANGE, start, end]
    CONST_EMPTY = :CONST_EMPTY       # [:CONST_EMPTY] - the 'empty' literal
    CONST_BLANK = :CONST_BLANK       # [:CONST_BLANK] - the 'blank' literal

    # Variable and property access
    FIND_VAR = :FIND_VAR             # [:FIND_VAR, name]
    FIND_VAR_PATH = :FIND_VAR_PATH   # [:FIND_VAR_PATH, name, [path]]
    FIND_VAR_DYNAMIC = :FIND_VAR_DYNAMIC  # [:FIND_VAR_DYNAMIC] - pops name from stack
    FIND_SELF = :FIND_SELF           # [:FIND_SELF] - pushes a SelfDrop wrapping the current scope
    LOOKUP_KEY = :LOOKUP_KEY         # [:LOOKUP_KEY] - pops key from stack
    LOOKUP_CONST_KEY = :LOOKUP_CONST_KEY  # [:LOOKUP_CONST_KEY, name]
    LOOKUP_CONST_PATH = :LOOKUP_CONST_PATH  # [:LOOKUP_CONST_PATH, [name, ...]]
    LOOKUP_COMMAND = :LOOKUP_COMMAND      # [:LOOKUP_COMMAND, name] - optimized for size/first/last

    # Capture opcodes
    PUSH_CAPTURE = :PUSH_CAPTURE     # [:PUSH_CAPTURE]
    POP_CAPTURE = :POP_CAPTURE       # [:POP_CAPTURE]

    # Control flow (loop-related; conditionals use the structured IF markers below)
    LABEL = :LABEL                   # [:LABEL, id]
    JUMP = :JUMP                     # [:JUMP, label_id]
    JUMP_IF_EMPTY = :JUMP_IF_EMPTY   # [:JUMP_IF_EMPTY, label_id]
    JUMP_IF_INTERRUPT = :JUMP_IF_INTERRUPT  # [:JUMP_IF_INTERRUPT, label_id]
    HALT = :HALT                     # [:HALT]

    # Comparison and logic
    COMPARE = :COMPARE               # [:COMPARE, op] where op is :eq/:ne/:lt/:le/:gt/:ge
    CASE_COMPARE = :CASE_COMPARE     # [:CASE_COMPARE] - case/when comparison (stricter blank/empty handling)
    CONTAINS = :CONTAINS             # [:CONTAINS]
    BOOL_NOT = :BOOL_NOT             # [:BOOL_NOT] - logical negation
    IS_TRUTHY = :IS_TRUTHY           # [:IS_TRUTHY] - convert to boolean
    BOOL_AND = :BOOL_AND             # [:BOOL_AND] - pops r, l; pushes truthy(l) && truthy(r)
    BOOL_OR = :BOOL_OR               # [:BOOL_OR]  - pops r, l; pushes truthy(l) || truthy(r)

    # Structured conditionals (block markers, always properly nested)
    # Emitted as: <condition ops> IS_TRUTHY [:IF, negate] <then ops> [[:ELSE] <else ops>] [:END_IF]
    # elsif desugars at parse time to ELSE + nested IF.
    IF = :IF                         # [:IF, negate] - pops condition; then-block runs when truthy (falsy if negate)
    ELSE = :ELSE                     # [:ELSE]
    END_IF = :END_IF                 # [:END_IF]

    # Scope and assignment
    PUSH_SCOPE = :PUSH_SCOPE         # [:PUSH_SCOPE]
    POP_SCOPE = :POP_SCOPE           # [:POP_SCOPE]
    ASSIGN = :ASSIGN                 # [:ASSIGN, name]
    ASSIGN_LOCAL = :ASSIGN_LOCAL     # [:ASSIGN_LOCAL, name] - assign to current scope (for loop vars)

    # Range opcodes
    NEW_RANGE = :NEW_RANGE           # [:NEW_RANGE] - pops end, start

    # Filter opcodes
    CALL_FILTER = :CALL_FILTER       # [:CALL_FILTER, name, argc, line]

    # Host-owned tag. The logical-template/source identity + zero-based slot
    # form a deterministic identity within cached artifacts; template_name is
    # supplied separately by codegen for host diagnostics and dispatch.
    # The exact tag source is baked into the artifact so a host can compile its
    # custom node once without reparsing the containing template on every
    # request.
    HOST_TAG = :HOST_TAG             # [:HOST_TAG, source_id, slot, name, line, source, effect_bits]
    HOST_TAG_READS_SCOPE = 0b001
    HOST_TAG_WRITES_SCOPE = 0b010
    HOST_TAG_CAN_INTERRUPT = 0b100
    HOST_TAG_DEFAULT_EFFECTS = (
      HOST_TAG_READS_SCOPE | HOST_TAG_WRITES_SCOPE | HOST_TAG_CAN_INTERRUPT
    )

    # Treat missing effect metadata as fully opaque. This keeps manually-built
    # and transitional IL conservative even though current parsers always
    # encode the bitset explicitly.
    def self.host_tag_effects(instruction)
      instruction[6] || HOST_TAG_DEFAULT_EFFECTS
    end

    def self.host_tag_reads_scope?(instruction)
      (host_tag_effects(instruction) & HOST_TAG_READS_SCOPE) != 0
    end

    def self.host_tag_writes_scope?(instruction)
      (host_tag_effects(instruction) & HOST_TAG_WRITES_SCOPE) != 0
    end

    def self.host_tag_can_interrupt?(instruction)
      (host_tag_effects(instruction) & HOST_TAG_CAN_INTERRUPT) != 0
    end

    # Loop and interrupt opcodes
    FOR_INIT = :FOR_INIT             # [:FOR_INIT, var_name, loop_name, has_limit, has_offset, offset_continue, reversed, recovery_label]
                                     #   recovery_label: label past the for block, reserved for error recovery (not read by codegen)
    FOR_NEXT = :FOR_NEXT             # [:FOR_NEXT, label_continue, label_break]
    FOR_END = :FOR_END               # [:FOR_END]
    PUSH_FORLOOP = :PUSH_FORLOOP     # [:PUSH_FORLOOP]
    POP_FORLOOP = :POP_FORLOOP       # [:POP_FORLOOP]
    PUSH_INTERRUPT = :PUSH_INTERRUPT # [:PUSH_INTERRUPT, type] where type is :break/:continue
    POP_INTERRUPT = :POP_INTERRUPT   # [:POP_INTERRUPT]

    # Counter opcodes
    INCREMENT = :INCREMENT           # [:INCREMENT, name]
    DECREMENT = :DECREMENT           # [:DECREMENT, name]

    # Cycle opcodes
    CYCLE_STEP = :CYCLE_STEP         # [:CYCLE_STEP, identity, values]
    CYCLE_STEP_VAR = :CYCLE_STEP_VAR # [:CYCLE_STEP_VAR, var_name, values] - group from variable

    # Partial opcodes (line = source line of the tag, for error messages)
    CONST_RENDER = :CONST_RENDER     # [:CONST_RENDER, name, args_map, line] - lowered by compiler
    CONST_INCLUDE = :CONST_INCLUDE   # [:CONST_INCLUDE, name, args_map, line] - lowered by compiler
    RENDER_PARTIAL = :RENDER_PARTIAL # [:RENDER_PARTIAL, name, args_map, line]
    INCLUDE_PARTIAL = :INCLUDE_PARTIAL  # [:INCLUDE_PARTIAL, name, args_map, line]

    # Tablerow opcodes
    TABLEROW_INIT = :TABLEROW_INIT   # [:TABLEROW_INIT, var_name, loop_name, has_limit, has_offset, cols]
                                     #   cols: nil (no cols attr) | Integer (literal) | :dynamic (value on stack) | :explicit_nil (cols:nil given)
    TABLEROW_NEXT = :TABLEROW_NEXT   # [:TABLEROW_NEXT, label_continue, label_break]
    TABLEROW_END = :TABLEROW_END     # [:TABLEROW_END]

    # Stack operations
    DUP = :DUP                       # [:DUP]
    POP = :POP                       # [:POP]
    BUILD_HASH = :BUILD_HASH         # [:BUILD_HASH, count] - pops count*2 items and pushes a Hash
    STORE_TEMP = :STORE_TEMP         # [:STORE_TEMP, index]
    LOAD_TEMP = :LOAD_TEMP           # [:LOAD_TEMP, index]

    # Ifchanged opcode
    IFCHANGED_CHECK = :IFCHANGED_CHECK  # [:IFCHANGED_CHECK, tag_id] - pops captured, outputs if changed

    # No-op (for comments, etc.)
    NOOP = :NOOP                     # [:NOOP]

    # Deduplicated statement run (synthetic — produced by the Ruby backend's
    # StatementDedup pass, consumed only by its codegen). Calls an
    # artifact-local lambda that replays a repeated run of statements.
    #   [:CALL_SEQ, seq_id, [arg_descriptor, ...]]
    # arg_descriptor: [:input, name, path] (value passed at the call site) or
    #                 [:name, str] (an assign-target name string).
    CALL_SEQ = :CALL_SEQ

    # Pre-frozen zero-arg instruction arrays
    I_WRITE_VALUE = [WRITE_VALUE].freeze
    I_PUSH_CAPTURE = [PUSH_CAPTURE].freeze
    I_POP_CAPTURE = [POP_CAPTURE].freeze
    I_HALT = [HALT].freeze
    I_CASE_COMPARE = [CASE_COMPARE].freeze
    I_CONTAINS = [CONTAINS].freeze
    I_BOOL_NOT = [BOOL_NOT].freeze
    I_IS_TRUTHY = [IS_TRUTHY].freeze
    I_BOOL_AND = [BOOL_AND].freeze
    I_BOOL_OR = [BOOL_OR].freeze
    I_ELSE = [ELSE].freeze
    I_END_IF = [END_IF].freeze
    I_PUSH_SCOPE = [PUSH_SCOPE].freeze
    I_POP_SCOPE = [POP_SCOPE].freeze
    I_NEW_RANGE = [NEW_RANGE].freeze
    I_FOR_END = [FOR_END].freeze
    I_PUSH_FORLOOP = [PUSH_FORLOOP].freeze
    I_POP_FORLOOP = [POP_FORLOOP].freeze
    I_POP_INTERRUPT = [POP_INTERRUPT].freeze
    I_TABLEROW_END = [TABLEROW_END].freeze
    I_DUP = [DUP].freeze
    I_POP = [POP].freeze
    I_NOOP = [NOOP].freeze
    I_CONST_NIL = [CONST_NIL].freeze
    I_CONST_TRUE = [CONST_TRUE].freeze
    I_CONST_FALSE = [CONST_FALSE].freeze
    I_CONST_EMPTY = [CONST_EMPTY].freeze
    I_CONST_BLANK = [CONST_BLANK].freeze
    I_FIND_VAR_DYNAMIC = [FIND_VAR_DYNAMIC].freeze
    I_FIND_SELF = [FIND_SELF].freeze
    I_LOOKUP_KEY = [LOOKUP_KEY].freeze

    # Instruction builder - creates instructions with minimal allocation
    class Builder
      # Post-melt, only loops allocate labels; label_counter == 0 means the
      # stream has no labels or jumps to link/strip at all.
      attr_reader :label_counter

      def initialize
        @instructions = []
        @label_counter = 0
      end

      def instructions
        @instructions
      end

      def new_label
        @label_counter += 1
      end

      def emit(opcode, *args)
        @instructions << (args.empty? ? [opcode] : [opcode, *args])
        self
      end

      # Specialized emitters for common arities (avoid *args splat overhead)
      def emit1(opcode, a)
        @instructions << [opcode, a]
        self
      end

      def emit2(opcode, a, b)
        @instructions << [opcode, a, b]
        self
      end

      def emit3(opcode, a, b, c)
        @instructions << [opcode, a, b, c]
        self
      end

      def emit_label(id)
        @instructions << [LABEL, id]
        self
      end

      # Merge instructions from another builder
      def emit_from(other)
        @instructions.concat(other.instructions)
        self
      end

      # Convenience methods
      def write_raw(str)
        emit1(WRITE_RAW, str)
      end

      def write_value
        @instructions << I_WRITE_VALUE; self
      end

      def const_nil
        @instructions << I_CONST_NIL; self
      end

      def const_true
        @instructions << I_CONST_TRUE; self
      end

      def const_false
        @instructions << I_CONST_FALSE; self
      end

      def const_int(val)
        emit1(CONST_INT, val)
      end

      def const_float(val)
        emit1(CONST_FLOAT, val)
      end

      def const_string(val)
        emit1(CONST_STRING, val)
      end

      def const_range(start_val, end_val)
        emit2(CONST_RANGE, start_val, end_val)
      end

      def const_empty
        @instructions << I_CONST_EMPTY; self
      end

      def const_blank
        @instructions << I_CONST_BLANK; self
      end

      def find_var(name)
        emit1(FIND_VAR, name)
      end

      def find_var_path(name, path)
        emit2(FIND_VAR_PATH, name, path)
      end

      def find_var_dynamic
        @instructions << I_FIND_VAR_DYNAMIC; self
      end

      def find_self
        @instructions << I_FIND_SELF; self
      end

      def lookup_key
        @instructions << I_LOOKUP_KEY; self
      end

      def lookup_const_key(name)
        # Sole owner of FIND_VAR(+path) + LOOKUP_CONST_KEY fusion: merging at
        # emit time means the pattern never reaches the optimizer (the old
        # collapse_find_var_paths pass never fired and was retired).
        last = @instructions.last
        if last && last[0] == FIND_VAR
          # FIND_VAR + LOOKUP_CONST_KEY → FIND_VAR_PATH
          @instructions.pop
          emit2(FIND_VAR_PATH, last[1], [name])
        elsif last && last[0] == FIND_VAR_PATH
          # Extend existing FIND_VAR_PATH
          last[2] << name
        else
          emit1(LOOKUP_CONST_KEY, name)
        end
      end

      def lookup_const_path(path)
        emit1(LOOKUP_CONST_PATH, path)
      end

      def lookup_command(name)
        emit1(LOOKUP_COMMAND, name)
      end

      def push_capture
        @instructions << I_PUSH_CAPTURE; self
      end

      def pop_capture
        @instructions << I_POP_CAPTURE; self
      end

      def label(id)
        emit_label(id)
      end

      def jump(label_id)
        emit1(JUMP, label_id)
      end

      def jump_if_empty(label_id)
        emit1(JUMP_IF_EMPTY, label_id)
      end

      def jump_if_interrupt(label_id)
        emit1(JUMP_IF_INTERRUPT, label_id)
      end

      def halt
        @instructions << I_HALT; self
      end

      def compare(op)
        emit1(COMPARE, op)
      end

      def case_compare
        @instructions << I_CASE_COMPARE; self
      end

      def contains
        @instructions << I_CONTAINS; self
      end

      def bool_not
        @instructions << I_BOOL_NOT; self
      end

      def is_truthy
        @instructions << I_IS_TRUTHY; self
      end

      def bool_and
        @instructions << I_BOOL_AND; self
      end

      def bool_or
        @instructions << I_BOOL_OR; self
      end

      def if_start(negate = false)
        emit1(IF, negate)
      end

      def else_start
        @instructions << I_ELSE; self
      end

      def end_if
        @instructions << I_END_IF; self
      end

      def push_scope
        @instructions << I_PUSH_SCOPE; self
      end

      def pop_scope
        @instructions << I_POP_SCOPE; self
      end

      def assign(name)
        emit1(ASSIGN, name)
      end

      def assign_local(name)
        emit1(ASSIGN_LOCAL, name)
      end

      def new_range
        @instructions << I_NEW_RANGE; self
      end

      def call_filter(name, argc, line = 1)
        emit3(CALL_FILTER, name, argc, line)
      end

      def host_tag(source_id, slot, name, line = 1, source = nil, effects = HOST_TAG_DEFAULT_EFFECTS)
        emit(HOST_TAG, source_id, slot, name, line, source, effects)
      end

      def for_init(var_name, loop_name, has_limit = false, has_offset = false, offset_continue = false, reversed = false, recovery_label = nil)
        emit(FOR_INIT, var_name, loop_name, has_limit, has_offset, offset_continue, reversed, recovery_label)
      end

      def for_next(label_continue, label_break)
        emit2(FOR_NEXT, label_continue, label_break)
      end

      def for_end
        @instructions << I_FOR_END; self
      end

      def push_forloop
        @instructions << I_PUSH_FORLOOP; self
      end

      def pop_forloop
        @instructions << I_POP_FORLOOP; self
      end

      def push_interrupt(type)
        emit1(PUSH_INTERRUPT, type)
      end

      def pop_interrupt
        @instructions << I_POP_INTERRUPT; self
      end

      def increment(name)
        emit1(INCREMENT, name)
      end

      def decrement(name)
        emit1(DECREMENT, name)
      end

      def cycle_step(identity, values)
        emit2(CYCLE_STEP, identity, values)
      end

      def cycle_step_var(var_name, values)
        emit2(CYCLE_STEP_VAR, var_name, values)
      end

      def render_partial(name, args, line = 1)
        emit3(RENDER_PARTIAL, name, args, line)
      end

      def include_partial(name, args, line = 1)
        emit3(INCLUDE_PARTIAL, name, args, line)
      end

      def const_render(name, args, line = 1)
        emit3(CONST_RENDER, name, args, line)
      end

      def const_include(name, args, line = 1)
        emit3(CONST_INCLUDE, name, args, line)
      end

      def tablerow_init(var_name, loop_name, has_limit, has_offset, cols)
        emit(TABLEROW_INIT, var_name, loop_name, has_limit, has_offset, cols)
      end

      def tablerow_next(label_continue, label_break)
        emit2(TABLEROW_NEXT, label_continue, label_break)
      end

      def tablerow_end
        @instructions << I_TABLEROW_END; self
      end

      def ifchanged_check(tag_id)
        emit1(IFCHANGED_CHECK, tag_id)
      end

      def dup
        @instructions << I_DUP; self
      end

      def pop
        @instructions << I_POP; self
      end

      def build_hash(count)
        emit1(BUILD_HASH, count)
      end

      def store_temp(index)
        emit1(STORE_TEMP, index)
      end

      def load_temp(index)
        emit1(LOAD_TEMP, index)
      end

      def noop
        @instructions << I_NOOP; self
      end
    end

    # Link labels to instruction indices
    def self.link(instructions)
      # Two-pass: first collect labels, then resolve jumps
      # Labels can appear after their first jump reference, requiring two passes
      label_positions = {}
      len = instructions.length
      i = 0
      while i < len
        inst = instructions[i]
        if inst[0] == LABEL
          label_positions[inst[1]] = i
        end
        i += 1
      end

      # Second pass: resolve jump targets using direct field access (faster than case)
      i = 0
      while i < len
        inst = instructions[i]
        opcode = inst[0]
        if opcode == JUMP || opcode == JUMP_IF_EMPTY || opcode == JUMP_IF_INTERRUPT
          inst[1] = label_positions[inst[1]] || raise("Unknown label: #{inst[1]}")
        elsif opcode == FOR_NEXT || opcode == TABLEROW_NEXT
          inst[1] = label_positions[inst[1]] || raise("Unknown label: #{inst[1]}")
          inst[2] = label_positions[inst[2]] || raise("Unknown label: #{inst[2]}")
        end
        i += 1
      end

      instructions
    end
  end
end
