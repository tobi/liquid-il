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
    LOOKUP_KEY = :LOOKUP_KEY         # [:LOOKUP_KEY] - pops key from stack
    LOOKUP_CONST_KEY = :LOOKUP_CONST_KEY  # [:LOOKUP_CONST_KEY, name]
    LOOKUP_CONST_PATH = :LOOKUP_CONST_PATH  # [:LOOKUP_CONST_PATH, [name, ...]]
    LOOKUP_COMMAND = :LOOKUP_COMMAND      # [:LOOKUP_COMMAND, name] - optimized for size/first/last

    # Capture opcodes
    PUSH_CAPTURE = :PUSH_CAPTURE     # [:PUSH_CAPTURE]
    POP_CAPTURE = :POP_CAPTURE       # [:POP_CAPTURE]

    # Control flow
    LABEL = :LABEL                   # [:LABEL, id]
    JUMP = :JUMP                     # [:JUMP, label_id]
    JUMP_IF_FALSE = :JUMP_IF_FALSE   # [:JUMP_IF_FALSE, label_id]
    JUMP_IF_TRUE = :JUMP_IF_TRUE     # [:JUMP_IF_TRUE, label_id]
    JUMP_IF_EMPTY = :JUMP_IF_EMPTY   # [:JUMP_IF_EMPTY, label_id]
    JUMP_IF_INTERRUPT = :JUMP_IF_INTERRUPT  # [:JUMP_IF_INTERRUPT, label_id]
    HALT = :HALT                     # [:HALT]

    # Comparison and logic
    COMPARE = :COMPARE               # [:COMPARE, op] where op is :eq/:ne/:lt/:le/:gt/:ge
    CASE_COMPARE = :CASE_COMPARE     # [:CASE_COMPARE] - case/when comparison (stricter blank/empty handling)
    CONTAINS = :CONTAINS             # [:CONTAINS]
    BOOL_NOT = :BOOL_NOT             # [:BOOL_NOT] - logical negation
    IS_TRUTHY = :IS_TRUTHY           # [:IS_TRUTHY] - convert to boolean

    # Scope and assignment
    PUSH_SCOPE = :PUSH_SCOPE         # [:PUSH_SCOPE]
    POP_SCOPE = :POP_SCOPE           # [:POP_SCOPE]
    ASSIGN = :ASSIGN                 # [:ASSIGN, name]
    ASSIGN_LOCAL = :ASSIGN_LOCAL     # [:ASSIGN_LOCAL, name] - assign to current scope (for loop vars)

    # Range opcodes
    NEW_RANGE = :NEW_RANGE           # [:NEW_RANGE] - pops end, start

    # Filter opcodes
    CALL_FILTER = :CALL_FILTER       # [:CALL_FILTER, name, argc]

    # Loop and interrupt opcodes
    FOR_INIT = :FOR_INIT             # [:FOR_INIT, var_name, loop_name, has_limit, has_offset, offset_continue, reversed]
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

    # Partial opcodes
    CONST_RENDER = :CONST_RENDER     # [:CONST_RENDER, name, args_map] - lowered by compiler
    CONST_INCLUDE = :CONST_INCLUDE   # [:CONST_INCLUDE, name, args_map] - lowered by compiler
    RENDER_PARTIAL = :RENDER_PARTIAL # [:RENDER_PARTIAL, name, args_map]
    INCLUDE_PARTIAL = :INCLUDE_PARTIAL  # [:INCLUDE_PARTIAL, name, args_map]

    # Tablerow opcodes
    TABLEROW_INIT = :TABLEROW_INIT   # [:TABLEROW_INIT, var_name, loop_name, has_limit, has_offset, cols]
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

    # Context tracking for error reporting in inlined partials
    SET_CONTEXT = :SET_CONTEXT       # [:SET_CONTEXT, file_name, source] - sets current file and source

    # No-op (for comments, etc.)
    NOOP = :NOOP                     # [:NOOP]

    # Pre-frozen zero-arg instruction arrays
    I_WRITE_VALUE = [WRITE_VALUE].freeze
    I_PUSH_CAPTURE = [PUSH_CAPTURE].freeze
    I_POP_CAPTURE = [POP_CAPTURE].freeze
    I_HALT = [HALT].freeze
    I_CASE_COMPARE = [CASE_COMPARE].freeze
    I_CONTAINS = [CONTAINS].freeze
    I_BOOL_NOT = [BOOL_NOT].freeze
    I_IS_TRUTHY = [IS_TRUTHY].freeze
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
    I_LOOKUP_KEY = [LOOKUP_KEY].freeze

    # Instruction builder - creates instructions with minimal allocation
    class Builder
      attr_reader :spans

      def initialize
        @instructions = []
        @spans = []  # Parallel array: [start_pos, end_pos] or nil
        @label_counter = 0
        @current_span = nil
      end

      def instructions
        @instructions
      end

      def new_label
        @label_counter += 1
      end

      # Set span for subsequent emits until cleared
      def with_span(start_pos)
        @current_span = start_pos
        self
      end

      def clear_span
        @current_span = nil
        self
      end

      def emit(opcode, *args)
        @instructions << (args.empty? ? [opcode] : [opcode, *args])
        @spans << @current_span
        self
      end

      def emit0(opcode)
        @instructions << [opcode]
        @spans << @current_span
        self
      end

      # Specialized emitters for common arities (avoid *args splat overhead)
      def emit1(opcode, a)
        @instructions << [opcode, a]
        @spans << @current_span
        self
      end

      def emit2(opcode, a, b)
        @instructions << [opcode, a, b]
        @spans << @current_span
        self
      end

      def emit_label(id)
        @instructions << [LABEL, id]
        @spans << nil  # Labels don't have source spans
        self
      end

      # Merge instructions and spans from another builder
      def emit_from(other)
        @instructions.concat(other.instructions)
        @spans.concat(other.spans)
        self
      end

      # Convenience methods
      def write_raw(str)
        emit1(WRITE_RAW, str)
      end

      def write_value
        @instructions << I_WRITE_VALUE; @spans << @current_span; self
      end

      def const_nil
        @instructions << I_CONST_NIL; @spans << @current_span; self
      end

      def const_true
        @instructions << I_CONST_TRUE; @spans << @current_span; self
      end

      def const_false
        @instructions << I_CONST_FALSE; @spans << @current_span; self
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
        @instructions << I_CONST_EMPTY; @spans << @current_span; self
      end

      def const_blank
        @instructions << I_CONST_BLANK; @spans << @current_span; self
      end

      def find_var(name)
        emit1(FIND_VAR, name)
      end

      def find_var_path(name, path)
        emit2(FIND_VAR_PATH, name, path)
      end

      def find_var_dynamic
        @instructions << I_FIND_VAR_DYNAMIC; @spans << @current_span; self
      end

      def lookup_key
        @instructions << I_LOOKUP_KEY; @spans << @current_span; self
      end

      def lookup_const_key(name)
        emit1(LOOKUP_CONST_KEY, name)
      end

      def lookup_const_path(path)
        emit1(LOOKUP_CONST_PATH, path)
      end

      def lookup_command(name)
        emit1(LOOKUP_COMMAND, name)
      end

      def push_capture
        @instructions << I_PUSH_CAPTURE; @spans << @current_span; self
      end

      def pop_capture
        @instructions << I_POP_CAPTURE; @spans << @current_span; self
      end

      def label(id)
        emit_label(id)
      end

      def jump(label_id)
        emit1(JUMP, label_id)
      end

      def jump_if_false(label_id)
        emit1(JUMP_IF_FALSE, label_id)
      end

      def jump_if_true(label_id)
        emit1(JUMP_IF_TRUE, label_id)
      end

      def jump_if_empty(label_id)
        emit1(JUMP_IF_EMPTY, label_id)
      end

      def jump_if_interrupt(label_id)
        emit1(JUMP_IF_INTERRUPT, label_id)
      end

      def halt
        @instructions << I_HALT; @spans << @current_span; self
      end

      def compare(op)
        emit1(COMPARE, op)
      end

      def case_compare
        @instructions << I_CASE_COMPARE; @spans << @current_span; self
      end

      def contains
        @instructions << I_CONTAINS; @spans << @current_span; self
      end

      def bool_not
        @instructions << I_BOOL_NOT; @spans << @current_span; self
      end

      def is_truthy
        @instructions << I_IS_TRUTHY; @spans << @current_span; self
      end

      def push_scope
        @instructions << I_PUSH_SCOPE; @spans << @current_span; self
      end

      def pop_scope
        @instructions << I_POP_SCOPE; @spans << @current_span; self
      end

      def assign(name)
        emit1(ASSIGN, name)
      end

      def assign_local(name)
        emit1(ASSIGN_LOCAL, name)
      end

      def new_range
        @instructions << I_NEW_RANGE; @spans << @current_span; self
      end

      def call_filter(name, argc)
        emit2(CALL_FILTER, name, argc)
      end

      def for_init(var_name, loop_name, has_limit = false, has_offset = false, offset_continue = false, reversed = false, recovery_label = nil)
        @instructions << [FOR_INIT, var_name, loop_name, has_limit, has_offset, offset_continue, reversed, recovery_label]
        @spans << @current_span
        self
      end

      def for_next(label_continue, label_break)
        emit2(FOR_NEXT, label_continue, label_break)
      end

      def for_end
        @instructions << I_FOR_END; @spans << @current_span; self
      end

      def push_forloop
        @instructions << I_PUSH_FORLOOP; @spans << @current_span; self
      end

      def pop_forloop
        @instructions << I_POP_FORLOOP; @spans << @current_span; self
      end

      def push_interrupt(type)
        emit1(PUSH_INTERRUPT, type)
      end

      def pop_interrupt
        @instructions << I_POP_INTERRUPT; @spans << @current_span; self
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

      def render_partial(name, args)
        emit2(RENDER_PARTIAL, name, args)
      end

      def include_partial(name, args)
        emit2(INCLUDE_PARTIAL, name, args)
      end

      def const_render(name, args)
        emit2(CONST_RENDER, name, args)
      end

      def const_include(name, args)
        emit2(CONST_INCLUDE, name, args)
      end

      def tablerow_init(var_name, loop_name, has_limit, has_offset, cols)
        @instructions << [TABLEROW_INIT, var_name, loop_name, has_limit, has_offset, cols]
        @spans << @current_span
        self
      end

      def tablerow_next(label_continue, label_break)
        emit2(TABLEROW_NEXT, label_continue, label_break)
      end

      def tablerow_end
        @instructions << I_TABLEROW_END; @spans << @current_span; self
      end

      def ifchanged_check(tag_id)
        emit1(IFCHANGED_CHECK, tag_id)
      end

      def dup
        @instructions << I_DUP; @spans << @current_span; self
      end

      def pop
        @instructions << I_POP; @spans << @current_span; self
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
        @instructions << I_NOOP; @spans << @current_span; self
      end
    end

    # Link labels to instruction indices
    def self.link(instructions)
      # First pass: find all label positions
      label_positions = {}
      instructions.each_with_index do |inst, idx|
        if inst[0] == LABEL
          label_positions[inst[1]] = idx
        end
      end

      # Second pass: resolve jumps
      instructions.each do |inst|
        case inst[0]
        when JUMP, JUMP_IF_FALSE, JUMP_IF_TRUE, JUMP_IF_EMPTY, JUMP_IF_INTERRUPT
          label_id = inst[1]
          inst[1] = label_positions[label_id] || raise("Unknown label: #{label_id}")
        when FOR_NEXT, TABLEROW_NEXT
          inst[1] = label_positions[inst[1]] || raise("Unknown label: #{inst[1]}")
          inst[2] = label_positions[inst[2]] || raise("Unknown label: #{inst[2]}")
        end
      end

      instructions
    end
  end
end
