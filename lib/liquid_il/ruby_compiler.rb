# frozen_string_literal: true

module LiquidIL
  # Compiles IL instructions to Ruby code for AOT execution.
  # Falls back to VM for unsupported instructions.
  class RubyCompiler
    # No longer have unsupported opcodes - partials are checked dynamically
    UNSUPPORTED_OPCODES = [].freeze

    class CompilationResult
      attr_reader :proc, :source, :can_compile, :partials

      def initialize(proc:, source:, can_compile:, partials: {})
        @proc = proc
        @source = source
        @can_compile = can_compile
        @partials = partials  # name -> { source:, instructions:, spans:, compiled_source: }
      end
    end

    def initialize(instructions, spans: nil, template_source: nil, context: nil, partials: nil, partial_names_in_progress: nil)
      @instructions = instructions
      @spans = spans
      @template_source = template_source
      @context = context
      @var_counter = 0
      @label_to_block = {}  # label_id -> block index where label appears
      @partials = partials || {}  # Shared partial cache across recursive compilations
      @partial_names_in_progress = partial_names_in_progress || Set.new  # Shared to prevent infinite recursion
      @uses_capture = detect_uses_capture
      @uses_interrupts = detect_uses_interrupts
      @forloop_usage = analyze_forloop_usage
    end

    # Check if template uses capture blocks (enables simpler output code when not)
    def detect_uses_capture
      @instructions.any? { |inst| inst[0] == IL::PUSH_CAPTURE }
    end

    # Check if template uses break/continue (enables simpler code without interrupt checks)
    # Include can propagate interrupts only if its compiled template can push one.
    def detect_uses_interrupts
      interrupt_possible_in_instructions?(@instructions)
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

    # Check if any loop uses forloop variable
    # Returns true if any forloop access exists in loops, or if include is used
    # inside a loop (since the included partial might access forloop.parentloop)
    def analyze_forloop_usage
      loop_depth = 0

      @instructions.each do |inst|
        case inst[0]
        when IL::FOR_INIT, IL::TABLEROW_INIT
          loop_depth += 1
        when IL::FOR_END, IL::TABLEROW_END
          loop_depth -= 1
        when IL::FIND_VAR
          return true if loop_depth > 0 && (inst[1] == "forloop" || inst[1] == "tablerowloop")
        when IL::FIND_VAR_PATH
          return true if loop_depth > 0 && (inst[1] == "forloop" || inst[1] == "tablerowloop")
        when IL::INCLUDE_PARTIAL
          # Include inside a loop might access forloop.parentloop
          return true if loop_depth > 0
        end
      end

      false
    end

    def compile
      return fallback_result unless can_compile?

      # Build control flow graph
      blocks = build_basic_blocks
      return fallback_result if blocks.empty?

      # Analyze and structure the code
      structured = analyze_structure(blocks)
      return fallback_result unless structured

      # Generate Ruby code
      ruby_code = generate_ruby(structured)
      return fallback_result unless ruby_code

      # Compile the Ruby code
      compiled_proc = eval_ruby(ruby_code)
      return fallback_result unless compiled_proc

      CompilationResult.new(
        proc: compiled_proc,
        source: ruby_code,
        can_compile: true,
        partials: @partials
      )
    rescue PartialCompilationError
      # A nested partial couldn't be compiled - fall back to VM
      fallback_result
    end

    # Error raised when partial compilation fails (e.g., missing nested partial)
    class PartialCompilationError < StandardError; end

    private

    def can_compile?
      @instructions.each do |inst|
        case inst[0]
        when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
          args = inst[2] || {}
          # Dynamic partials cannot be compiled - require runtime resolution
          return false if args["__dynamic_name__"]
          # Invalid partial names (nil, non-string) need VM for proper error handling
          return false if args["__invalid_name__"]
          # If no file system, can't load partials - fall back to VM
          return false unless @context&.file_system
        end
        return false if UNSUPPORTED_OPCODES.include?(inst[0])
      end
      true
    end

    # Error raised when a dynamic partial is encountered (kept for backward compatibility)
    class DynamicPartialError < StandardError; end

    def fallback_result
      CompilationResult.new(proc: nil, source: nil, can_compile: false)
    end

    # Basic block: sequence of instructions with single entry/exit
    BasicBlock = Data.define(:id, :instructions, :indices, :successors, :predecessors) do
      def initialize(id:, instructions: [], indices: [], successors: [], predecessors: [])
        super
      end
    end

    def build_basic_blocks
      return [] if @instructions.empty?

      # Find block leaders (first instruction, jump targets, instruction after jumps)
      leaders = Set.new([0])

      @instructions.each_with_index do |inst, idx|
        case inst[0]
        when IL::JUMP
          leaders << inst[1]
          leaders << (idx + 1) if idx + 1 < @instructions.length
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
          leaders << inst[1]
          leaders << (idx + 1) if idx + 1 < @instructions.length
        when IL::FOR_NEXT, IL::TABLEROW_NEXT
          leaders << inst[1]  # continue label
          leaders << inst[2]  # break label
          leaders << (idx + 1)
        when IL::HALT
          leaders << (idx + 1) if idx + 1 < @instructions.length
        when IL::LABEL
          leaders << idx
        end
      end

      # Build blocks from leaders
      sorted_leaders = leaders.to_a.select { |l| l < @instructions.length }.sort
      blocks = []

      sorted_leaders.each_with_index do |start, block_idx|
        next_leader = sorted_leaders[block_idx + 1] || @instructions.length
        block_insts = []
        block_indices = []

        (start...next_leader).each do |i|
          block_insts << @instructions[i]
          block_indices << i
        end

        blocks << BasicBlock.new(
          id: block_idx,
          instructions: block_insts,
          indices: block_indices,
          successors: [],
          predecessors: []
        )

        # Track label positions
        if block_insts.first && block_insts.first[0] == IL::LABEL
          @label_to_block[start] = block_idx
        end
        # Also track by the actual instruction index for jump targets
        @label_to_block[start] = block_idx
      end

      # Connect blocks with edges
      blocks.each_with_index do |block, idx|
        next if block.instructions.empty?

        last_inst = block.instructions.last
        case last_inst[0]
        when IL::HALT
          # No successors
        when IL::JUMP
          target_block = @label_to_block[last_inst[1]]
          block.successors << target_block if target_block
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY
          # Fall through and jump target
          block.successors << (idx + 1) if idx + 1 < blocks.length
          target_block = @label_to_block[last_inst[1]]
          block.successors << target_block if target_block
        when IL::JUMP_IF_INTERRUPT
          # Fall through and jump target
          block.successors << (idx + 1) if idx + 1 < blocks.length
          target_block = @label_to_block[last_inst[1]]
          block.successors << target_block if target_block
        when IL::FOR_NEXT
          # Fall through (has next item) and break label
          block.successors << (idx + 1) if idx + 1 < blocks.length
          target_block = @label_to_block[last_inst[2]]  # break label
          block.successors << target_block if target_block
        else
          # Fall through to next block
          block.successors << (idx + 1) if idx + 1 < blocks.length
        end

        block.successors.uniq!
      end

      # Build predecessor lists
      blocks.each_with_index do |block, idx|
        block.successors.each do |succ_idx|
          blocks[succ_idx].predecessors << idx if blocks[succ_idx]
        end
      end

      blocks
    end

    # Structured code representation
    StructuredCode = Data.define(:type, :children, :data) do
      def initialize(type:, children: [], data: {})
        super
      end
    end

    def analyze_structure(blocks)
      # For now, generate simple sequential code with gotos simulated via methods
      # Later: detect if/else and for patterns
      StructuredCode.new(type: :sequence, children: blocks)
    end

    # Default output buffer capacity (8KB)
    OUTPUT_CAPACITY = 8192

    def generate_ruby(structured)
      code = String.new
      code << "# frozen_string_literal: true\n"
      code << "proc do |__scope__, __spans__, __template_source__|\n"
      code << "  __output__ = String.new(capacity: #{OUTPUT_CAPACITY})\n"
      code << "  __stack__ = []\n"
      code << "  __for_iterators__ = []\n"
      code << "  __current_file__ = nil\n"
      code << "\n"
      code << generate_ruby_body(structured)
      code << "\n  __output__\n"
      code << "end\n"

      code
    end

    # Generate partial method definitions for the runtime proc
    def generate_runtime_partial_methods
      return "" if @partials.empty?

      code = String.new
      @partials.each do |name, info|
        method_name = partial_method_name(name)
        body = info[:compiled_body]

        code << "\n"
        code << "def #{method_name}(assigns, __output__, __parent_scope__, isolated, caller_line: 1)\n"
        code << "  # Save and set file context for error reporting\n"
        code << "  __prev_file__ = __parent_scope__.current_file\n"
        code << "  __parent_scope__.current_file = #{name.inspect}\n"
        code << "\n"
        code << "  # Check render depth to prevent infinite recursion\n"
        code << "  __parent_scope__.push_render_depth\n"
        code << "  if __parent_scope__.render_depth_exceeded?(strict: !isolated)\n"
        code << "    raise LiquidIL::RuntimeError.new(\"Nesting too deep\", file: #{name.inspect}, line: caller_line)\n"
        code << "  end\n"
        code << "\n"
        code << "  __scope__ = isolated ? __parent_scope__.isolated : __parent_scope__\n"
        code << "  assigns.each { |k, v| __scope__.assign(k, v) }\n"
        code << "  __spans__ = #{info[:spans].inspect}\n"
        code << "  __template_source__ = #{info[:source].inspect}\n"
        code << "  __stack__ = []\n"
        code << "  __for_iterators__ = []\n"
        code << "  __current_file__ = #{name.inspect}\n"
        code << "\n"
        code << body
        code << "rescue LiquidIL::RuntimeError => e\n"
        code << "  raise unless __parent_scope__.render_errors\n"
        code << "  __write_output__(e.partial_output, __output__, __scope__) if e.partial_output\n"
        code << "  location = e.file ? \"\#{e.file} line \#{e.line}\" : \"line \#{e.line}\"\n"
        code << "  __write_output__(\"Liquid error (\#{location}): \#{e.message}\", __output__, __scope__)\n"
        code << "rescue StandardError => e\n"
        code << "  raise unless __parent_scope__.render_errors\n"
        code << "  __write_output__(\"Liquid error (#{name} line 1): \#{LiquidIL.clean_error_message(e.message)}\", __output__, __scope__)\n"
        code << "ensure\n"
        code << "  __parent_scope__.current_file = __prev_file__\n"
        code << "  __parent_scope__.pop_render_depth\n"
        code << "end\n"
      end

      code
    end

    # Generate just the body code (for partials and standalone files)
    def generate_ruby_body(structured)
      blocks = structured.children

      # Check if we need state machine (any jumps/conditionals)
      needs_state_machine = false
      blocks.each do |block|
        next if block.instructions.empty?
        block.instructions.each do |inst|
          case inst[0]
          when IL::JUMP, IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
            needs_state_machine = true
          when IL::FOR_NEXT
            needs_state_machine = true
          end
        end
      end

      if needs_state_machine
        generate_state_machine(blocks)
      else
        generate_straight_line(blocks)
      end
    end

    def generate_straight_line(blocks)
      code = String.new

      blocks.each do |block|
        i = 0
        while i < block.instructions.length
          inst = block.instructions[i]

          # Batch consecutive WRITE_RAW instructions
          if inst[0] == IL::WRITE_RAW
            raw_strings = [inst[1]]
            j = i + 1
            while j < block.instructions.length && block.instructions[j][0] == IL::WRITE_RAW
              raw_strings << block.instructions[j][1]
              j += 1
            end

            if raw_strings.length > 1
              # Batch multiple raw strings into one output call
              combined = raw_strings.join
              if @uses_capture
                code << "  __write_output__(#{combined.inspect}, __output__, __scope__)\n"
              elsif @uses_interrupts
                code << "  __output__ << #{combined.inspect} unless __scope__.has_interrupt?\n"
              else
                code << "  __output__ << #{combined.inspect}\n"
              end
              i = j
              next
            end
          end

          # Try to generate direct expression for output patterns
          expr_result = try_generate_direct_expression(block.instructions, i, "  ")
          if expr_result
            code << expr_result[:code]
            i += expr_result[:consumed]
          else
            code << generate_instruction(inst, block.indices[i])
            i += 1
          end
        end
      end

      code
    end

    # Try to generate a direct expression for common patterns like:
    # FIND_VAR + WRITE_VALUE, FIND_VAR + LOOKUP + WRITE_VALUE, etc.
    # Returns { code: String, consumed: Integer } or nil if pattern doesn't match
    def try_generate_direct_expression(instructions, start_idx, indent = "  ")
      return nil if start_idx >= instructions.length

      inst = instructions[start_idx]
      opcode = inst[0]

      # Pattern: FIND_VAR [+ lookups/filters] + WRITE_VALUE
      if opcode == IL::FIND_VAR
        expr, consumed, preamble, can_error = build_expression_chain(instructions, start_idx)
        return nil unless expr && consumed > 1  # Must consume more than just FIND_VAR

        # Check if chain ends with WRITE_VALUE
        last_idx = start_idx + consumed - 1
        if last_idx < instructions.length && instructions[last_idx][0] == IL::WRITE_VALUE
          output_code = generate_output_expression(expr, indent, preamble, can_error: can_error)
          return { code: output_code, consumed: consumed }
        end
      end

      # Pattern: FIND_VAR_PATH [+ lookups/filters] + WRITE_VALUE
      if opcode == IL::FIND_VAR_PATH
        expr, consumed, preamble, can_error = build_expression_chain(instructions, start_idx)
        return nil unless expr && consumed > 1

        last_idx = start_idx + consumed - 1
        if last_idx < instructions.length && instructions[last_idx][0] == IL::WRITE_VALUE
          output_code = generate_output_expression(expr, indent, preamble, can_error: can_error)
          return { code: output_code, consumed: consumed }
        end
      end

      # Pattern: LOAD_TEMP [+ lookups/filters] + WRITE_VALUE (cached value)
      if opcode == IL::LOAD_TEMP
        expr, consumed, preamble, can_error = build_expression_chain(instructions, start_idx)
        return nil unless expr && consumed > 1

        last_idx = start_idx + consumed - 1
        if last_idx < instructions.length && instructions[last_idx][0] == IL::WRITE_VALUE
          output_code = generate_output_expression(expr, indent, preamble, can_error: can_error)
          return { code: output_code, consumed: consumed }
        end
      end

      nil
    end

    # Build an expression chain from instructions starting at idx
    # Returns [expression_string, instructions_consumed, preamble, can_error] or nil
    # can_error is true if the expression includes operations that can produce ErrorMarker
    def build_expression_chain(instructions, start_idx)
      return nil if start_idx >= instructions.length

      inst = instructions[start_idx]
      idx = start_idx
      expr = nil
      preamble = nil  # Optional code to run before the expression (for temp caching)
      can_error = false  # Track if any operation in the chain can produce ErrorMarker

      # Start with variable lookup or cached temp
      case inst[0]
      when IL::FIND_VAR
        expr = "__scope__.lookup(#{inst[1].inspect})"
        idx += 1
      when IL::FIND_VAR_PATH
        name, path = inst[1], inst[2]
        if path.length == 1
          expr = "__lookup_property__(__scope__.lookup(#{name.inspect}), #{path[0].inspect})"
        else
          expr = "__lookup_path__(__scope__.lookup(#{name.inspect}), #{path.map(&:inspect).join(", ")})"
        end
        idx += 1
      when IL::LOAD_TEMP
        # Using cached value
        expr = "__t#{inst[1]}__"
        idx += 1
      else
        return nil
      end

      # Follow chain of operations
      while idx < instructions.length
        next_inst = instructions[idx]

        case next_inst[0]
        when IL::LOOKUP_CONST_KEY
          # Inline Hash fast path: most template data is Hashes
          key = next_inst[1]
          expr = inline_hash_lookup(expr, key)
          idx += 1
        when IL::LOOKUP_CONST_PATH
          path = next_inst[1]
          if path.length == 1
            expr = inline_hash_lookup(expr, path[0])
          else
            expr = "__lookup_path__(#{expr}, #{path.map(&:inspect).join(", ")})"
          end
          idx += 1
        when IL::CALL_FILTER
          name, argc = next_inst[1], next_inst[2]
          if argc == 0
            expr = "__call_filter__(#{name.inspect}, #{expr}, [], __scope__, __spans__, __template_source__, #{idx}, __current_file__)"
            can_error = true  # Filters can produce ErrorMarker
          else
            # Filters with args are complex - bail out for now
            # TODO: could handle constant args
            break
          end
          idx += 1
        when IL::DUP
          # DUP for caching - check if followed by STORE_TEMP
          if idx + 1 < instructions.length && instructions[idx + 1][0] == IL::STORE_TEMP
            temp_idx = instructions[idx + 1][1]
            # Generate preamble to cache the value and update expr to use the temp
            preamble = "__t#{temp_idx}__ = #{expr}; "
            expr = "__t#{temp_idx}__"
            idx += 2  # Skip both DUP and STORE_TEMP
          else
            # Standalone DUP - bail out
            break
          end
        when IL::WRITE_VALUE
          # End of expression - include this in consumed count
          idx += 1
          break
        else
          # Unknown operation - stop here
          break
        end
      end

      [expr, idx - start_idx, preamble, can_error]
    end

    # Generate inline Hash lookup code for expression chains
    # Avoids __lookup_property__ method call for normal Hash keys
    # For special keys (first, last, size, length), we must call the helper
    def inline_hash_lookup(expr, key)
      key_str = key.inspect

      # Special keys require full lookup (Hash.first returns key-value pair, etc.)
      if %w[first last size length].include?(key.to_s)
        return "__lookup_property__(#{expr}, #{key_str})"
      end

      # For normal keys, try string then symbol
      "((__h__ = #{expr}; __h__.is_a?(Hash)) ? ((__hv__ = __h__[#{key_str}]; __hv__.nil? ? __h__[#{key.to_sym.inspect}] : __hv__)) : __lookup_property__(__h__, #{key_str}))"
    end

    # Generate inline Hash lookup code for instruction generation
    # Can either return an expression or a statement that pushes to stack
    def generate_inline_hash_lookup(expr, key, pop_input: false)
      key_str = key.inspect

      # Special keys require full lookup (Hash.first returns key-value pair, etc.)
      if %w[first last size length].include?(key.to_s)
        if pop_input
          return "__o__ = #{expr}; __stack__ << __lookup_property__(__o__, #{key_str})"
        else
          return "__lookup_property__(#{expr}, #{key_str})"
        end
      end

      # For normal keys, inline the Hash fast path
      key_sym = key.to_sym.inspect
      if pop_input
        "__o__ = #{expr}; __stack__ << ((__o__.is_a?(Hash)) ? ((__hv__ = __o__[#{key_str}]; __hv__.nil? ? __o__[#{key_sym}] : __hv__)) : __lookup_property__(__o__, #{key_str}))"
      else
        "((__h__ = #{expr}; __h__.is_a?(Hash)) ? ((__hv__ = __h__[#{key_str}]; __hv__.nil? ? __h__[#{key_sym}] : __hv__)) : __lookup_property__(__h__, #{key_str}))"
      end
    end

    # Generate optimized output code for an expression
    # can_error: if false, skip the ErrorMarker check (for operations that can't produce errors)
    def generate_output_expression(expr, indent, preamble = nil, can_error: true)
      # Inline fast path: String passes through, Integer/Float calls .to_s, others use helper
      # This avoids method call overhead for the most common cases (strings from lookups/filters)
      output_expr = if can_error
                      # Need to check for ErrorMarker first
                      "(__v__ = #{expr}; __v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__(__v__))"
                    else
                      # No error possible - inline the type check
                      "(__v__ = #{expr}; __v__.is_a?(String) ? __v__ : __output_string__(__v__))"
                    end

      code = String.new
      code << "#{indent}#{preamble}\n" if preamble

      if @uses_capture
        code << "#{indent}__write_output__(#{output_expr}, __output__, __scope__)\n"
      elsif @uses_interrupts
        code << "#{indent}__output__ << #{output_expr} unless __scope__.has_interrupt?\n"
      else
        code << "#{indent}__output__ << #{output_expr}\n"
      end

      code
    end

    def generate_state_machine(blocks)
      code = String.new
      code << "  __pc__ = 0\n"
      code << "  while true\n"
      code << "    case __pc__\n"

      blocks.each do |block|
        code << "    when #{block.id}\n"

        if block.instructions.empty?
          code << "      __pc__ += 1\n"
          next
        end

        i = 0
        while i < block.instructions.length
          inst = block.instructions[i]
          global_idx = block.indices[i]

          # Batch consecutive WRITE_RAW instructions
          if inst[0] == IL::WRITE_RAW
            raw_strings = [inst[1]]
            j = i + 1
            while j < block.instructions.length && block.instructions[j][0] == IL::WRITE_RAW
              raw_strings << block.instructions[j][1]
              j += 1
            end

            if raw_strings.length > 1
              # Batch multiple raw strings into one output call
              combined = raw_strings.join
              if @uses_capture
                code << "      __write_output__(#{combined.inspect}, __output__, __scope__)\n"
              elsif @uses_interrupts
                code << "      __output__ << #{combined.inspect} unless __scope__.has_interrupt?\n"
              else
                code << "      __output__ << #{combined.inspect}\n"
              end
              i = j
              next
            end
          end

          # Try to generate direct expression for output patterns
          expr_result = try_generate_direct_expression(block.instructions, i, "      ")
          if expr_result
            code << expr_result[:code]
            i += expr_result[:consumed]
          else
            inst_code = generate_instruction_for_state_machine(inst, global_idx, block)
            code << inst_code
            i += 1
          end
        end

        # Handle control flow
        last = block.instructions.last
        case last[0]
        when IL::HALT
          code << "      break\n"
        when IL::JUMP
          target = @label_to_block[last[1]]
          code << "      __pc__ = #{target}\n"
        when IL::JUMP_IF_FALSE, IL::JUMP_IF_TRUE, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT, IL::FOR_NEXT, IL::TABLEROW_NEXT
          # Already handled in instruction generation
          nil
        else
          code << "      __pc__ = #{block.id + 1}\n"
        end
      end

      code << "    else\n"
      code << "      break\n"
      code << "    end\n"
      code << "  end\n"

      code
    end

    def generate_instruction(inst, idx)
      opcode = inst[0]

      case opcode
      when IL::LABEL
        "  # label #{inst[1]}\n"
      when IL::HALT
        "  # halt\n"
      when IL::NOOP
        ""
      when IL::SET_CONTEXT
        file_name = inst[1]
        source = inst[2]
        "  __current_file__ = #{file_name.inspect}; __template_source__ = #{source.inspect}; __scope__.current_file = __current_file__\n"
      when IL::WRITE_RAW
        if @uses_capture
          "  __write_output__(#{inst[1].inspect}, __output__, __scope__)\n"
        elsif @uses_interrupts
          # Need interrupt check (break/continue possible)
          "  __output__ << #{inst[1].inspect} unless __scope__.has_interrupt?\n"
        else
          # Fast path: no capture, no interrupts - direct write
          "  __output__ << #{inst[1].inspect}\n"
        end
      when IL::WRITE_VALUE
        # Inline String check for fast path, use __output_string__ for others
        if @uses_capture
          "  __v__ = __stack__.pop; __write_output__(__v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__(__v__), __output__, __scope__)\n"
        elsif @uses_interrupts
          # Need interrupt check (break/continue possible)
          "  __v__ = __stack__.pop; __output__ << (__v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__(__v__)) unless __scope__&.has_interrupt?\n"
        else
          # Fast path: no capture, no interrupts - direct write
          "  __v__ = __stack__.pop; __output__ << (__v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : __v__.is_a?(String) ? __v__ : __output_string__(__v__))\n"
        end
      when IL::WRITE_VAR
        # Fused FIND_VAR + WRITE_VALUE (no stack needed, no ErrorMarker possible)
        # Inline String check for fast path
        if @uses_capture
          "  __v__ = __scope__.lookup(#{inst[1].inspect}); __write_output__(__v__.is_a?(String) ? __v__ : __output_string__(__v__), __output__, __scope__)\n"
        elsif @uses_interrupts
          "  __v__ = __scope__.lookup(#{inst[1].inspect}); __output__ << (__v__.is_a?(String) ? __v__ : __output_string__(__v__)) unless __scope__&.has_interrupt?\n"
        else
          "  __v__ = __scope__.lookup(#{inst[1].inspect}); __output__ << (__v__.is_a?(String) ? __v__ : __output_string__(__v__))\n"
        end
      when IL::WRITE_VAR_PATH
        # Fused FIND_VAR_PATH + WRITE_VALUE (no stack needed, no ErrorMarker possible)
        # Inline String check and Hash lookup for fast path
        name, path = inst[1], inst[2]
        lookup_expr = if path.length == 1
          # Inline Hash fast path for single property (handles special keys too)
          key = path[0]
          generate_inline_hash_lookup("__scope__.lookup(#{name.inspect})", key)
        else
          "__lookup_path__(__scope__.lookup(#{name.inspect}), #{path.map(&:inspect).join(", ")})"
        end
        if @uses_capture
          "  __v__ = #{lookup_expr}; __write_output__(__v__.is_a?(String) ? __v__ : __output_string__(__v__), __output__, __scope__)\n"
        elsif @uses_interrupts
          "  __v__ = #{lookup_expr}; __output__ << (__v__.is_a?(String) ? __v__ : __output_string__(__v__)) unless __scope__&.has_interrupt?\n"
        else
          "  __v__ = #{lookup_expr}; __output__ << (__v__.is_a?(String) ? __v__ : __output_string__(__v__))\n"
        end
      when IL::CONST_NIL
        "  __stack__ << nil\n"
      when IL::CONST_TRUE
        "  __stack__ << true\n"
      when IL::CONST_FALSE
        "  __stack__ << false\n"
      when IL::CONST_INT
        "  __stack__ << #{inst[1]}\n"
      when IL::CONST_FLOAT
        val = inst[1]
        # Handle special float values
        val_str = if val.nan?
                    "Float::NAN"
                  elsif val.infinite? == 1
                    "Float::INFINITY"
                  elsif val.infinite? == -1
                    "-Float::INFINITY"
                  else
                    val.inspect
                  end
        "  __stack__ << #{val_str}\n"
      when IL::CONST_STRING
        "  __stack__ << #{inst[1].inspect}\n"
      when IL::CONST_RANGE
        "  __stack__ << LiquidIL::RangeValue.new(#{inst[1]}, #{inst[2]})\n"
      when IL::CONST_EMPTY
        "  __stack__ << LiquidIL::EmptyLiteral.instance\n"
      when IL::CONST_BLANK
        "  __stack__ << LiquidIL::BlankLiteral.instance\n"
      when IL::FIND_VAR
        "  __stack__ << __scope__.lookup(#{inst[1].inspect})\n"
      when IL::FIND_VAR_DYNAMIC
        "  __stack__ << __scope__.lookup(__stack__.pop.to_s)\n"
      when IL::FIND_VAR_PATH
        name, path = inst[1], inst[2]
        if path.length == 1
          # Single property - inline Hash fast path for normal keys
          key = path[0]
          lookup_code = generate_inline_hash_lookup("__scope__.lookup(#{name.inspect})", key)
          "  __stack__ << #{lookup_code}\n"
        else
          # Multiple properties - use optimized path lookup
          "  __stack__ << __lookup_path__(__scope__.lookup(#{name.inspect}), #{path.map(&:inspect).join(", ")})\n"
        end
      when IL::LOOKUP_KEY
        "  __k__ = __stack__.pop; __o__ = __stack__.pop; __stack__ << __lookup_key__(__o__, __k__)\n"
      when IL::LOOKUP_CONST_KEY
        # Inline Hash fast path for normal keys
        key = inst[1]
        lookup_code = generate_inline_hash_lookup("__stack__.pop", key, pop_input: true)
        "  #{lookup_code}\n"
      when IL::LOOKUP_CONST_PATH
        path = inst[1]
        if path.length == 1
          # Single property - inline Hash fast path for normal keys
          key = path[0]
          lookup_code = generate_inline_hash_lookup("__stack__.pop", key, pop_input: true)
          "  #{lookup_code}\n"
        else
          # Multiple properties - use optimized path lookup
          "  __stack__ << __lookup_path__(__stack__.pop, #{path.map(&:inspect).join(", ")})\n"
        end
      when IL::LOOKUP_COMMAND
        "  __stack__ << __execute_command__(__stack__.pop, #{inst[1].inspect})\n"
      when IL::PUSH_CAPTURE
        "  __scope__.push_capture\n"
      when IL::POP_CAPTURE
        "  __stack__ << __scope__.pop_capture\n"
      when IL::COMPARE
        "  __r__ = __stack__.pop; __l__ = __stack__.pop; __stack__ << __compare_with_error__(__l__, __r__, #{inst[1].inspect}, __output__, __scope__, __current_file__)\n"
      when IL::CASE_COMPARE
        "  __r__ = __stack__.pop; __l__ = __stack__.pop; __stack__ << __case_compare__(__l__, __r__)\n"
      when IL::CONTAINS
        "  __r__ = __stack__.pop; __l__ = __stack__.pop; __stack__ << __contains__(__l__, __r__)\n"
      when IL::BOOL_NOT
        "  __stack__ << !__is_truthy__(__stack__.pop)\n"
      when IL::IS_TRUTHY
        "  __stack__ << __is_truthy__(__stack__.pop)\n"
      when IL::PUSH_SCOPE
        "  __scope__.push_scope\n"
      when IL::POP_SCOPE
        "  __scope__.pop_scope\n"
      when IL::ASSIGN
        "  __v__ = __stack__.pop; __scope__.assign(#{inst[1].inspect}, __v__) unless __v__.is_a?(LiquidIL::ErrorMarker)\n"
      when IL::ASSIGN_LOCAL
        "  __v__ = __stack__.pop; __scope__.assign_local(#{inst[1].inspect}, __v__) unless __v__.is_a?(LiquidIL::ErrorMarker)\n"
      when IL::NEW_RANGE
        "  __e__ = __stack__.pop; __s__ = __stack__.pop; __stack__ << __new_range__(__s__, __e__, __output__, __scope__, __current_file__)\n"
      when IL::CALL_FILTER
        arg_count = inst[2]
        if arg_count == 0
          # Avoid allocating empty array for zero-arg filters
          "  __input__ = __stack__.pop; __stack__ << __call_filter__(#{inst[1].inspect}, __input__, [], __scope__, __spans__, __template_source__, #{idx}, __current_file__)\n"
        else
          "  __args__ = __stack__.pop(#{arg_count}); __input__ = __stack__.pop; __stack__ << __call_filter__(#{inst[1].inspect}, __input__, __args__, __scope__, __spans__, __template_source__, #{idx}, __current_file__)\n"
        end
      when IL::INCREMENT
        "  __stack__ << __scope__.increment(#{inst[1].inspect})\n"
      when IL::DECREMENT
        "  __stack__ << __scope__.decrement(#{inst[1].inspect})\n"
      when IL::CYCLE_STEP
        "  __stack__ << __cycle_step__(#{inst[1].inspect}, #{inst[2].inspect}, __scope__)\n"
      when IL::CYCLE_STEP_VAR
        "  __id__ = LiquidIL::Utils.output_string(__scope__.lookup(#{inst[1].inspect})); __stack__ << __cycle_step__(__id__, #{inst[2].inspect}, __scope__)\n"
      when IL::DUP
        "  __stack__ << __stack__.last\n"
      when IL::POP
        "  __stack__.pop\n"
      when IL::BUILD_HASH
        "  __pairs__ = __stack__.pop(#{inst[1] * 2}); __h__ = {}; __i__ = 0; while __i__ < __pairs__.length; __h__[__pairs__[__i__].to_s] = __pairs__[__i__+1]; __i__ += 2; end; __stack__ << __h__\n"
      when IL::STORE_TEMP
        "  __t#{inst[1]}__ = __stack__.pop\n"
      when IL::LOAD_TEMP
        "  __stack__ << __t#{inst[1]}__\n"
      when IL::IFCHANGED_CHECK
        "  __captured__ = __stack__.pop; __prev__ = __scope__.get_ifchanged_state(#{inst[1].inspect}); if __captured__ != __prev__; __scope__.set_ifchanged_state(#{inst[1].inspect}, __captured__); __output__ << __captured__.to_s; end\n"
      when IL::PUSH_INTERRUPT
        "  __scope__.push_interrupt(#{inst[1].inspect})\n"
      when IL::POP_INTERRUPT
        # Only emit if template uses break/continue
        @uses_interrupts ? "  __scope__.pop_interrupt\n" : ""
      when IL::PUSH_FORLOOP
        if @forloop_usage
          <<~RUBY
            __iter__ = __for_iterators__.last
            __parent__ = __scope__.current_forloop
            __forloop__ = LiquidIL::ForloopDrop.new(__iter__&.name || "", __iter__&.length || 0, __parent__)
            __scope__.push_forloop(__forloop__)
            __scope__.assign_local("forloop", __forloop__)
          RUBY
        else
          # forloop not used - skip ForloopDrop creation entirely
          ""
        end
      when IL::POP_FORLOOP
        @forloop_usage ? "  __scope__.pop_forloop\n" : ""
      when IL::RENDER_PARTIAL
        generate_partial_call(inst, idx, isolated: true)
      when IL::INCLUDE_PARTIAL
        # Add check for include being disabled (inside render context)
        name = inst[1]
        code = String.new
        code << "  if __scope__.disable_include\n"
        code << "    raise LiquidIL::RuntimeError.new(\"include usage is not allowed in this context\", file: __current_file__, line: 1, partial_output: __output__.dup)\n"
        code << "  else\n"
        code << generate_partial_call(inst, idx, isolated: false).gsub(/^/, "  ")
        code << "  end\n"
        code
      else
        "  # unsupported: #{opcode}\n"
      end
    end

    def generate_partial_call(inst, idx, isolated:)
      name = inst[1]
      args = inst[2] || {}

      # Ensure this partial is compiled (unless it's already being compiled - recursive case)
      compile_partial(name) unless @partials[name] || @partial_names_in_progress.include?(name)

      method_name = partial_method_name(name)
      tag_type = isolated ? "render" : "include"

      # Compute caller line for error reporting
      caller_line_expr = "__compute_line__(__spans__, __template_source__, #{idx})"

      # Build sequential argument assignments
      # For include (non-isolated), args are evaluated in order and each is assigned to the scope
      # so that later args can reference earlier ones (e.g., a: 1, b: a)
      sequential_arg_code = String.new
      sequential_arg_code << "  __partial_args__ = {}\n"
      has_regular_args = false
      args.each do |k, v|
        next if k.start_with?("__")
        has_regular_args = true
        if v.is_a?(Hash) && v[:__var__]
          # Variable lookup - handles both simple vars and dotted paths
          var_path = v[:__var__]
          expr = if var_path.is_a?(Array)
                   generate_eval_expression(var_path[0])
                 else
                   generate_eval_expression(var_path)
                 end
          sequential_arg_code << "  __partial_args__[#{k.inspect}] = #{expr}\n"
          # For include (non-isolated), also assign to current scope so later args can read it
          unless isolated
            sequential_arg_code << "  __scope__.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
          end
        else
          sequential_arg_code << "  __partial_args__[#{k.inspect}] = #{v.inspect}\n"
          unless isolated
            sequential_arg_code << "  __scope__.assign(#{k.inspect}, __partial_args__[#{k.inspect}])\n"
          end
        end
      end

      code = String.new
      code << "  # #{tag_type} '#{name}'\n"
      code << "  __caller_line__ = #{caller_line_expr}\n"

      # Handle with/for expressions
      with_expr = args["__with__"]
      for_expr = args["__for__"]
      as_alias = args["__as__"]

      if for_expr
        # Render once per item in collection - match VM semantics exactly
        # IMPORTANT: Evaluate for expression BEFORE sequential args, to match VM behavior
        var_expr = generate_eval_expression(for_expr)
        item_var = as_alias || name
        code << "  __for_coll_raw__ = #{var_expr}\n"
        code << sequential_arg_code
        code << "  if __for_coll_raw__.is_a?(Array)\n"
        code << "    # Arrays: iterate (empty = don't render)\n"
        code << "    __for_coll_raw__.each_with_index do |__item__, __idx__|\n"
        code << "      __partial_args__[#{item_var.inspect}] = __item__\n"
        if isolated
          code << "      __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __for_coll_raw__.length).tap { |f| f.index0 = __idx__ }\n"
        end
        code << "      #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        code << "    end\n"
        if isolated
          # Ranges iterate for render (isolated) but not for include
          code << "  elsif __for_coll_raw__.is_a?(LiquidIL::RangeValue) || __for_coll_raw__.is_a?(Range)\n"
          code << "    # Ranges: iterate for render\n"
          code << "    __items__ = __for_coll_raw__.to_a\n"
          code << "    __items__.each_with_index do |__item__, __idx__|\n"
          code << "      __partial_args__[#{item_var.inspect}] = __item__\n"
          code << "      __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = __idx__ }\n"
          code << "      #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
          code << "    end\n"
        end
        code << "  elsif !__for_coll_raw__.is_a?(Hash) && !__for_coll_raw__.is_a?(String) && !__for_coll_raw__.is_a?(Range) && !__for_coll_raw__.is_a?(LiquidIL::RangeValue) && __for_coll_raw__.respond_to?(:each) && __for_coll_raw__.respond_to?(:to_a)\n"
        code << "    # Enumerable drops: iterate\n"
        code << "    __items__ = __for_coll_raw__.to_a\n"
        code << "    __items__.each_with_index do |__item__, __idx__|\n"
        code << "      __partial_args__[#{item_var.inspect}] = __item__\n"
        if isolated
          code << "      __partial_args__['forloop'] = LiquidIL::ForloopDrop.new('forloop', __items__.length).tap { |f| f.index0 = __idx__ }\n"
        end
        code << "      #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        code << "    end\n"
        code << "  elsif __for_coll_raw__.nil?\n"
        code << "    # Nil: render once with named args only (don't set item var)\n"
        code << "    #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        code << "  else\n"
        code << "    # Scalar value (int, string, hash, range for include): render once with that value\n"
        code << "    __partial_args__[#{item_var.inspect}] = __for_coll_raw__\n"
        code << "    #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        code << "  end\n"
      elsif with_expr
        # Render with a specific value
        # IMPORTANT: Evaluate with expression BEFORE sequential args, to match VM behavior
        var_expr = generate_eval_expression(with_expr)
        item_var = as_alias || name
        code << "  __with_val__ = #{var_expr}\n"
        code << sequential_arg_code
        if isolated
          # For render (isolated): arrays render once as single item
          # nil/undefined with value lets keyword arg take precedence
          code << "  __partial_args__[#{item_var.inspect}] = __with_val__ unless __with_val__.nil?\n"
          code << "  #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        else
          # For include (non-isolated) with arrays: iterate like "for"
          code << "  if __with_val__.is_a?(Array)\n"
          code << "    __with_val__.each do |__item__|\n"
          code << "      __partial_args__[#{item_var.inspect}] = __item__\n"
          code << "      #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
          code << "    end\n"
          code << "  else\n"
          code << "    # with value always overrides (even nil)\n"
          code << "    __partial_args__[#{item_var.inspect}] = __with_val__\n"
          code << "    #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
          code << "  end\n"
        end
      else
        # Simple render
        if has_regular_args
          code << sequential_arg_code
          code << "  #{method_name}(__partial_args__, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        else
          code << "  #{method_name}({}, __output__, __scope__, #{isolated}, caller_line: __caller_line__)\n"
        end
      end

      code
    end

    # Generate Ruby code to evaluate an expression (handles literals, ranges, and variables)
    # This compiles the expression at build time instead of parsing at runtime
    def generate_eval_expression(expr)
      return "nil" unless expr
      expr_str = expr.to_s

      # Handle string literals (quoted strings)
      if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
        return Regexp.last_match(1).inspect
      end

      # Handle range literals (1..10)
      if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
        return "LiquidIL::RangeValue.new(#{Regexp.last_match(1)}, #{Regexp.last_match(2)})"
      end

      # Parse variable path at compile time (avoids runtime regex/string parsing)
      parts = expr_str.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
      return "nil" if parts.empty?

      if parts.size == 1
        # Simple variable lookup - most common case
        "__scope__.lookup(#{parts[0][0].inspect})"
      else
        # Multi-part path: __lookup_path__(__scope__.lookup("var"), "prop1", "prop2")
        first_var = parts[0][0]
        rest_keys = parts[1..].map do |match|
          key = match[0] || match[1] || match[2]
          key.to_s =~ /^\d+$/ ? key.to_i : key.inspect
        end
        "__lookup_path__(__scope__.lookup(#{first_var.inspect}), #{rest_keys.join(", ")})"
      end
    end

    def compile_partial(name)
      return if @partials[name]
      return if @partial_names_in_progress.include?(name)

      @partial_names_in_progress.add(name)

      # Load the partial source
      fs = @context&.file_system
      source = if fs.respond_to?(:read_template_file)
                 fs.read_template_file(name) rescue nil
               elsif fs.respond_to?(:read)
                 fs.read(name)
               end

      unless source
        raise PartialCompilationError, "Cannot load partial '#{name}': no file system available or partial not found"
      end

      # Compile the partial - syntax errors fall back to VM
      begin
        compiler = LiquidIL::Compiler.new(source, optimize: true)
        result = compiler.compile
      rescue LiquidIL::SyntaxError => e
        raise PartialCompilationError, "Partial '#{name}' has syntax error: #{e.message}"
      end
      instructions = result[:instructions]
      spans = result[:spans]

      # Recursively compile to Ruby (sharing partials cache and in-progress set)
      ruby_compiler = RubyCompiler.new(
        instructions,
        spans: spans,
        template_source: source,
        context: @context,
        partials: @partials,
        partial_names_in_progress: @partial_names_in_progress
      )

      # Check for dynamic partials in this partial
      ruby_compiler.send(:can_compile?)

      # Build basic blocks and generate code for this partial
      blocks = ruby_compiler.send(:build_basic_blocks)
      structured = ruby_compiler.send(:analyze_structure, blocks)
      partial_code = ruby_compiler.send(:generate_ruby_body, structured)

      @partials[name] = {
        source: source,
        instructions: instructions,
        spans: spans,
        compiled_body: partial_code
      }

      @partial_names_in_progress.delete(name)
    end

    def partial_method_name(name)
      # Convert partial name to valid Ruby method name
      "__partial_#{name.gsub(/[^a-zA-Z0-9_]/, '_')}__"
    end

    def generate_instruction_for_state_machine(inst, idx, block)
      opcode = inst[0]

      case opcode
      when IL::JUMP
        ""  # Handled in control flow
      when IL::JUMP_IF_FALSE
        target = @label_to_block[inst[1]]
        <<~RUBY
              __v__ = __stack__.pop
              if __is_truthy__(__v__)
                __pc__ = #{block.id + 1}
              else
                __pc__ = #{target}
              end
        RUBY
      when IL::JUMP_IF_TRUE
        target = @label_to_block[inst[1]]
        <<~RUBY
              __v__ = __stack__.pop
              if __is_truthy__(__v__)
                __pc__ = #{target}
              else
                __pc__ = #{block.id + 1}
              end
        RUBY
      when IL::JUMP_IF_EMPTY
        target = @label_to_block[inst[1]]
        <<~RUBY
              __v__ = __stack__.last
              if __is_collection_empty__(__v__)
                __stack__.pop
                __pc__ = #{target}
              else
                __pc__ = #{block.id + 1}
              end
        RUBY
      when IL::JUMP_IF_INTERRUPT
        target = @label_to_block[inst[1]]
        if @uses_interrupts
          # Template has break/continue - need full interrupt handling
          <<~RUBY
                if __scope__.has_interrupt?
                  __int__ = __scope__.pop_interrupt
                  if __int__ == :continue
                    __pc__ = #{block.id + 1}
                  else
                    __pc__ = #{target}
                  end
                else
                  __pc__ = #{block.id + 1}
                end
          RUBY
        else
          # No break/continue - simple fall-through
          "      __pc__ = #{block.id + 1}\n"
        end
      when IL::FOR_INIT
        var_name, loop_name, has_limit, has_offset, offset_continue, reversed, recovery_label = inst[1..]
        recovery_target = recovery_label ? @label_to_block[recovery_label] : "(__pc__ = #{block.id + 1}; break)"
        # IL emits: offset, limit (in that order) so limit is on top of stack
        <<~RUBY
              __limit__ = #{has_limit} ? __stack__.pop : nil
              __offset__ = #{has_offset} ? __stack__.pop : nil
              __coll__ = __stack__.pop
              __iter__ = __create_iterator__(__coll__, #{loop_name.inspect}, #{has_limit}, __limit__, #{has_offset}, __offset__, #{offset_continue}, #{reversed}, __scope__, __output__)
              __for_iterators__ << __iter__
        RUBY
      when IL::FOR_NEXT
        continue_label, break_label = inst[1], inst[2]
        continue_target = @label_to_block[continue_label]
        break_target = @label_to_block[break_label]
        if @forloop_usage
          <<~RUBY
                __iter__ = __for_iterators__.last
                __forloop__ = __scope__.current_forloop
                __forloop__.index0 = __iter__.index0 if __forloop__ && __iter__
                if __iter__ && __iter__.has_next?
                  __stack__ << __iter__.next_value
                  __pc__ = #{block.id + 1}
                else
                  __pc__ = #{break_target}
                end
          RUBY
        else
          # forloop not used - skip forloop index update
          <<~RUBY
                __iter__ = __for_iterators__.last
                if __iter__ && __iter__.has_next?
                  __stack__ << __iter__.next_value
                  __pc__ = #{block.id + 1}
                else
                  __pc__ = #{break_target}
                end
          RUBY
        end
      when IL::FOR_END
        <<~RUBY
              __iter__ = __for_iterators__.pop
              __scope__.set_for_offset(__iter__.name, __iter__.next_offset) if __iter__
        RUBY
      when IL::TABLEROW_INIT
        var_name, loop_name, has_limit, has_offset, cols = inst[1..]
        # Pass cols type info separately:
        # - nil (no cols) → :default
        # - :explicit_nil (cols:nil literal) → :explicit_nil
        # - :dynamic (cols:var) → :dynamic, value popped from stack
        # - integer → the actual value
        cols_code, cols_type = case cols
                               when :dynamic then ['__stack__.pop', ':dynamic']
                               when :explicit_nil then ['nil', ':explicit_nil']
                               when nil then ['nil', ':default']
                               else [cols.inspect, ':static']
                               end
        <<~RUBY
              __cols__ = #{cols_code}
              __cols_type__ = #{cols_type}
              __offset__ = #{has_offset} ? __stack__.pop : nil
              __limit__ = #{has_limit} ? __stack__.pop : nil
              __coll__ = __stack__.pop
              __iter__ = __create_tablerow_iterator__(__coll__, #{loop_name.inspect}, #{has_limit}, __limit__, #{has_offset}, __offset__, __cols__, __cols_type__, __scope__, __output__)
              __for_iterators__ << __iter__
        RUBY
      when IL::TABLEROW_NEXT
        continue_label, break_label = inst[1], inst[2]
        continue_target = @label_to_block[continue_label]
        break_target = @label_to_block[break_label]
        <<~RUBY
              __iter__ = __for_iterators__.last
              if __iter__ && __iter__.has_next?
                __tablerow_output_tags__(__iter__, __output__, __scope__)
                __stack__ << __iter__.next_value
                __tablerowloop__ = LiquidIL::TablerowloopDrop.new(__iter__.name, __iter__.length, __iter__.cols, nil, __iter__.cols_explicit_nil)
                __tablerowloop__.index0 = __iter__.index0 - 1
                __scope__.assign_local('tablerowloop', __tablerowloop__)
                __pc__ = #{block.id + 1}
              else
                if __iter__ && __iter__.index0 == 0 && !__iter__.skip_output
                  __write_output__("<tr class=\\"row1\\">\\n", __output__, __scope__)
                end
                __pc__ = #{break_target}
              end
        RUBY
      when IL::TABLEROW_END
        <<~RUBY
              __iter__ = __for_iterators__.pop
              __tablerow_close_tags__(__iter__, __output__, __scope__)
        RUBY
      else
        # Use standard generation with proper indentation
        code = generate_instruction(inst, idx)
        code.gsub(/^  /, "      ")
      end
    end

    def eval_ruby(source)
      # Define helper methods in the binding
      helpers = Module.new do
        extend self

        def __write_output__(str, output, scope)
          return unless str
          return if scope&.has_interrupt?
          # Fast path: skip .to_s for strings (most common case)
          str = str.to_s unless str.is_a?(String)
          if scope&.capturing?
            scope.current_capture << str
          else
            output << str
          end
        end

        # Inlined output_string for non-String values (String handled inline in generated code)
        # This is faster than calling LiquidIL::Utils.output_string because it avoids module lookup
        def __output_string__(value)
          case value
          when Integer, Float
            value.to_s
          when nil
            "".freeze
          when true
            "true".freeze
          when false
            "false".freeze
          when Array
            value.map { |item| item.is_a?(String) ? item : __output_string__(item) }.join
          else
            LiquidIL::Utils.output_string(value)
          end
        end

        def __call_filter__(name, input, args, scope, spans, source, inst_idx, current_file = nil)
          LiquidIL::Filters.apply(name, input, args, scope)
        rescue LiquidIL::FilterError
          # Filter error in non-strict mode - push nil so ASSIGN assigns nil
          nil
        rescue LiquidIL::FilterRuntimeError => e
          # Filter runtime error - raise or return ErrorMarker based on render_errors setting
          line = __compute_line__(spans, source, inst_idx)
          if scope.render_errors
            location = current_file ? "#{current_file} line #{line}" : "line #{line}"
            LiquidIL::ErrorMarker.new(e.message, location)
          else
            raise LiquidIL::RuntimeError.new(e.message, file: current_file, line: line)
          end
        end

        def __compute_line__(spans, source, inst_idx)
          return 1 unless spans && source && inst_idx
          span = spans[inst_idx]
          return 1 unless span
          pos = span[0] || 0
          source[0, pos].count("\n") + 1
        end

        def __compare_with_error__(left, right, op, output, scope, current_file = nil)
          __compare__(left, right, op)
        rescue ArgumentError => e
          location = current_file ? "#{current_file} line 1" : "line 1"
          __write_output__("Liquid error (#{location}): #{e.message}", output, scope)
          false
        end

        def __new_range__(start_val, end_val, output, scope, current_file = nil)
          if start_val.is_a?(Float) || end_val.is_a?(Float)
            location = current_file ? "#{current_file} line 1" : "line 1"
            return LiquidIL::ErrorMarker.new("invalid integer", location)
          end
          LiquidIL::RangeValue.new(start_val, end_val)
        end

        def __is_truthy__(value)
          # Fast path for common types that don't have to_liquid_value
          case value
          when nil, false, LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral
            false
          when true, String, Integer, Float, Array, Hash
            true
          else
            value = value.to_liquid_value if value.respond_to?(:to_liquid_value)
            !value.nil? && value != false
          end
        end

        def __is_collection_empty__(value)
          case value
          when nil then true
          when Array, Hash, String then value.empty?
          when LiquidIL::RangeValue then value.length <= 0
          else
            __to_iterable__(value).empty?
          end
        end

        def __lookup_key__(obj, key)
          return nil if obj.nil?
          # Fast path: strings/integers don't have to_liquid_value
          key = key.to_liquid_value if !key.is_a?(String) && !key.is_a?(Integer) && key.respond_to?(:to_liquid_value)
          return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)

          case obj
          when Hash
            result = obj[key]
            return result unless result.nil?
            result = obj[key.to_s]
            return result unless result.nil?
            obj[key.to_sym] if key.is_a?(String)
          when Array
            if key.is_a?(Integer)
              obj[key]
            elsif key.to_s =~ /\A-?\d+\z/
              obj[key.to_i]
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop
            obj[key]
          when String
            if key.is_a?(Integer)
              obj[key]
            elsif key.to_s =~ /\A-?\d+\z/
              obj[key.to_i]
            end
          else
            obj[key] if obj.respond_to?(:[])
          end
        end

        def __lookup_property__(obj, key)
          return nil if obj.nil?
          # Fast path: strings don't have to_liquid_value
          key = key.to_liquid_value if !key.is_a?(String) && key.respond_to?(:to_liquid_value)

          case obj
          when Hash
            # Fast path: key is usually already a string
            key_str = key.is_a?(String) ? key : key.to_s
            result = obj[key_str]
            return result unless result.nil?
            result = obj[key_str.to_sym]
            return result unless result.nil?
            case key_str
            when "first"
              pair = obj.first
              pair ? "#{pair[0]}#{pair[1]}" : nil
            when "size", "length"
              obj.length
            end
          when Array
            if key.is_a?(Integer)
              obj[key]
            else
              case key.to_s
              when "size", "length" then obj.length
              when "first" then obj.first
              when "last" then obj.last
              else obj[key.to_i]
              end
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop
            obj[key]
          when LiquidIL::RangeValue
            case key.to_s
            when "first" then obj.first
            when "last" then obj.last
            when "size", "length" then obj.length
            end
          when String
            case key.to_s
            when "size", "length" then obj.length
            when "first" then obj[0]
            when "last" then obj[-1]
            end
          when Integer
            obj.size if key.to_s == "size"
          when Float
            nil
          else
            if key.is_a?(String) && obj.respond_to?(key.to_sym)
              obj.send(key.to_sym)
            elsif obj.respond_to?(:[])
              obj[key.to_s]
            end
          end
        end

        # Optimized path lookup - inline Hash fast path, single method call for chains
        def __lookup_path__(obj, *keys)
          keys.each do |k|
            return nil if obj.nil?
            if obj.is_a?(Hash)
              # Fast path: Hash is most common
              result = obj[k]
              obj = result.nil? ? obj[k.to_sym] : result
            else
              obj = __lookup_property__(obj, k)
            end
          end
          obj
        end

        def __execute_command__(obj, command)
          case command
          when "size", "length"
            case obj
            when Array, String, Hash then obj.length
            when LiquidIL::RangeValue then obj.length
            else obj.length if obj.respond_to?(:length)
            end
          when "first"
            case obj
            when Array then obj.first
            when LiquidIL::RangeValue then obj.start_val
            end
          when "last"
            case obj
            when Array then obj.last
            when LiquidIL::RangeValue then obj.end_val
            end
          end
        end

        def __compare__(left, right, op)
          left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
          right = right.to_liquid_value if right.respond_to?(:to_liquid_value)
          left = LiquidIL::RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
          right = LiquidIL::RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

          if right.is_a?(LiquidIL::EmptyLiteral)
            return false if left.is_a?(LiquidIL::EmptyLiteral) || left.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(left) if op == :eq
            return !__is_empty__(left) if op == :ne
          end
          if right.is_a?(LiquidIL::BlankLiteral)
            return false if left.is_a?(LiquidIL::EmptyLiteral) || left.is_a?(LiquidIL::BlankLiteral)
            return __is_blank__(left) if op == :eq
            return !__is_blank__(left) if op == :ne
          end
          if left.is_a?(LiquidIL::EmptyLiteral)
            return __is_empty__(right) if op == :eq
            return !__is_empty__(right) if op == :ne
          end
          if left.is_a?(LiquidIL::BlankLiteral)
            return __is_blank__(right) if op == :eq
            return !__is_blank__(right) if op == :ne
          end

          case op
          when :eq then left == right
          when :ne then left != right
          when :lt then __compare_numeric__(left, right, :lt)
          when :le then __compare_numeric__(left, right, :le)
          when :gt then __compare_numeric__(left, right, :gt)
          when :ge then __compare_numeric__(left, right, :ge)
          else false
          end
        end

        def __case_compare__(left, right)
          left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
          right = right.to_liquid_value if right.respond_to?(:to_liquid_value)
          left = LiquidIL::RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
          right = LiquidIL::RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

          if left.is_a?(LiquidIL::BlankLiteral) || left.is_a?(LiquidIL::EmptyLiteral)
            return __is_blank_strict__(right) if left.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(right) if left.is_a?(LiquidIL::EmptyLiteral)
          end
          if right.is_a?(LiquidIL::BlankLiteral) || right.is_a?(LiquidIL::EmptyLiteral)
            return __is_blank__(left) if right.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(left) if right.is_a?(LiquidIL::EmptyLiteral)
          end
          left == right
        end

        def __is_empty__(value)
          case value
          when LiquidIL::EmptyLiteral then true
          when String, Array, Hash then value.empty?
          else false
          end
        end

        def __is_blank__(value)
          case value
          when LiquidIL::BlankLiteral, nil, false then true
          when String then value.empty? || value.strip.empty?
          when Array, Hash then value.empty?
          else false
          end
        end

        def __is_blank_strict__(value)
          case value
          when LiquidIL::BlankLiteral, nil, false then true
          when String then value.empty?
          when Array, Hash then value.empty?
          else false
          end
        end

        def __compare_numeric__(left, right, op)
          return false if left.nil? || right.nil?
          return false if left == true || left == false || right == true || right == false
          return false if left.is_a?(Array) || left.is_a?(Hash) || right.is_a?(Array) || right.is_a?(Hash)
          return false if left.is_a?(LiquidIL::RangeValue) || right.is_a?(LiquidIL::RangeValue)

          left_num = __to_number__(left)
          right_num = __to_number__(right)
          if left_num.nil? || right_num.nil?
            # Format: show value for numbers, class for other types
            right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
            raise ArgumentError, "comparison of #{left.class} with #{right_str} failed"
          end

          case op
          when :lt then left_num < right_num
          when :le then left_num <= right_num
          when :gt then left_num > right_num
          when :ge then left_num >= right_num
          else false
          end
        end

        def __to_number__(value)
          case value
          when Integer, Float then value
          when String
            if value =~ /\A-?\d+\z/
              value.to_i
            elsif value =~ /\A-?\d+\.\d+\z/
              value.to_f
            end
          end
        end

        def __contains__(left, right)
          return false if right.nil?
          case left
          when String
            right_str = right.to_s
            # Handle encoding mismatches gracefully
            if left.encoding != right_str.encoding
              begin
                left = left.dup.force_encoding(Encoding::UTF_8)
                right_str = right_str.dup.force_encoding(Encoding::UTF_8)
              rescue
                return false
              end
            end
            left.include?(right_str) rescue false
          when Array then left.include?(right)
          when Hash then left.key?(right.to_s) || (right.is_a?(String) && left.key?(right.to_sym))
          else false
          end
        end

        def __cycle_step__(identity, values, scope)
          resolved = values.map do |v|
            if v.is_a?(Array) && v.length == 2
              type, val = v
              if type == :lit
                val
              elsif type == :var
                scope.lookup(val)
              else
                val
              end
            else
              v
            end
          end
          scope.cycle_step(identity, resolved)
        end

        def __to_iterable__(value)
          case value
          when nil, true, false, Integer, Float then []
          when String then value.empty? ? [] : [value]
          when LiquidIL::RangeValue then value.to_a
          when Array then value
          when Hash then value.map { |k, v| [k, v] }
          else
            if value.respond_to?(:to_a)
              value.to_a rescue (value.respond_to?(:each) ? value.to_enum.to_a : [])
            elsif value.respond_to?(:each)
              value.to_enum.to_a
            else
              []
            end
          end
        end

        def __eval_expression__(expr, scope)
          return nil unless expr
          expr_str = expr.to_s

          # Handle string literals (quoted strings)
          if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
            return Regexp.last_match(1)
          end

          # Handle range literals (1..10)
          if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
            return LiquidIL::RangeValue.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
          end

          # Parse variable path: product.name or items[0]
          parts = expr_str.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
          return nil if parts.empty?

          result = nil
          parts.each_with_index do |match, idx|
            if idx == 0
              # First part is always a variable name
              result = scope.lookup(match[0])
            else
              # Subsequent parts are property access
              key = match[0] || match[1] || match[2]
              result = __lookup_property__(result, key.to_s =~ /^\d+$/ ? key.to_i : key)
            end
          end
          result
        end

        def __valid_integer__(value)
          return true if value.nil? || value.is_a?(Integer) || value.is_a?(Float)
          return true if value.is_a?(String) && value =~ /\A-?\d/
          false
        end

        def __to_integer__(value)
          num = __to_number__(value)
          num ? num.to_i : 0
        end

        def __create_iterator__(collection, loop_name, has_limit, limit, has_offset, offset, offset_continue, reversed, scope, output)
          is_nil_collection = collection.nil? || collection == false
          is_string_collection = collection.is_a?(String)
          items = __to_iterable__(collection)

          # Validate limit/offset only if collection is defined
          unless is_nil_collection
            if has_limit && !__valid_integer__(limit)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::ForIterator.new([], loop_name, start_offset: 0, offset_continue: false)
            end
            if has_offset && !__valid_integer__(offset)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::ForIterator.new([], loop_name, start_offset: 0, offset_continue: false)
            end
          end

          from = 0
          if offset_continue
            from = scope.for_offset(loop_name)
          elsif !offset.nil?
            from = __to_integer__(offset)
          end

          to = nil
          if !limit.nil?
            limit_val = __to_integer__(limit)
            to = from + limit_val
          end

          items = __slice_collection__(items, from, to, is_string: is_string_collection)
          items = items.reverse if reversed
          actual_offset = [from, 0].max

          LiquidIL::ForIterator.new(items, loop_name, start_offset: actual_offset, offset_continue: offset_continue)
        end

        def __slice_collection__(collection, from, to, is_string: false)
          return collection if is_string
          segments = []
          index = 0
          collection.each do |item|
            break if to && to <= index
            segments << item if from <= index
            index += 1
          end
          segments
        end

        def __create_tablerow_iterator__(collection, loop_name, has_limit, limit, has_offset, offset, cols, cols_type, scope, output)
          is_nil_collection = collection.nil? || collection == false
          is_string_collection = collection.is_a?(String)
          items = __to_iterable__(collection)

          # Process cols value based on type
          cols_explicit_nil = false
          case cols_type
          when :explicit_nil
            # cols:nil literal - use items.length, col_last always false
            cols_explicit_nil = true
            cols = items.length
          when :dynamic
            # cols:var - if nil, col_last always false
            if cols.nil?
              cols_explicit_nil = true
              cols = items.length
            elsif cols.is_a?(Integer)
              # Keep as is
            elsif cols.is_a?(Float)
              cols = cols.to_i
            elsif cols.is_a?(String) && cols =~ /\A-?\d+(?:\.\d+)?\z/
              cols = cols.to_i
            elsif !is_nil_collection
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: 1, skip_output: true)
            end
          when :default
            # No cols specified - use items.length, col_last works normally
            cols = items.length
          when :static
            # Static integer value - keep as is
          end

          # Validate limit/offset only if collection is defined
          unless is_nil_collection
            if has_limit && !__valid_integer__(limit)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: cols || 1, skip_output: true)
            end
            if has_offset && !__valid_integer__(offset)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: cols || 1, skip_output: true)
            end
          end

          if has_offset && !is_string_collection
            start_offset = offset.nil? ? 0 : __to_integer__(offset)
            start_offset = [start_offset, 0].max
            items = items.drop(start_offset) if start_offset > 0
          end

          # For tablerow, nil limit means 0 items (but not for strings)
          if has_limit && limit.nil? && !is_string_collection
            items = []
          elsif has_limit && !is_string_collection
            limit_val = __to_integer__(limit)
            limit_val = [limit_val, 0].max
            items = items.take(limit_val)
          end

          LiquidIL::TablerowIterator.new(items, loop_name, cols: cols, skip_output: is_nil_collection, cols_explicit_nil: cols_explicit_nil)
        end

        def __tablerow_output_tags__(iter, output, scope)
          return if iter.skip_output
          # Close previous cell/row if not first iteration
          if iter.index0 > 0
            __write_output__("</td>", output, scope)
            if iter.at_row_end?
              __write_output__("</tr>\n", output, scope)
            end
          end

          # Open new row if at start of row
          if iter.at_row_start?
            if iter.row == 1
              __write_output__("<tr class=\"row#{iter.row}\">\n", output, scope)
            else
              __write_output__("<tr class=\"row#{iter.row}\">", output, scope)
            end
          end
          __write_output__("<td class=\"col#{iter.col}\">", output, scope)
        end

        def __tablerow_close_tags__(iter, output, scope)
          return unless iter && !iter.skip_output
          if iter.index0 > 0
            __write_output__("</td>", output, scope)
            __write_output__("</tr>\n", output, scope)
          elsif iter.index0 == 0
            __write_output__("</tr>\n", output, scope)
          end
        end
      end

      # Add partial methods to the helpers module
      partial_code = generate_runtime_partial_methods
      unless partial_code.empty?
        helpers.module_eval(partial_code)
      end

      # Create proc with helpers in scope
      binding_obj = helpers.instance_eval { binding }
      eval(source, binding_obj)
    rescue SyntaxError, StandardError => e
      nil
    end
  end

  # A compiled template that uses the generated Ruby proc
  class CompiledTemplate
    attr_reader :source, :instructions, :spans, :compiled_source, :uses_vm, :partials

    def initialize(source, instructions, spans, context, compiled_result)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @uses_vm = !compiled_result.can_compile
      @partials = compiled_result.partials || {}
    end

    def render(assigns = {}, render_errors: true, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = Scope.new(assigns, registers: @context&.registers&.dup || {}, strict_errors: @context&.strict_errors || false)
      scope.file_system = @context&.file_system
      scope.render_errors = render_errors

      if @uses_vm
        # Fall back to VM
        VM.execute(@instructions, scope, spans: @spans, source: @source)
      else
        # Use compiled proc
        @compiled_proc.call(scope, @spans, @source)
      end
    rescue LiquidIL::RuntimeError => e
      raise unless render_errors
      output = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output + "Liquid error (#{location}): #{e.message}"
    rescue StandardError => e
      raise unless render_errors
      location = scope.current_file ? "#{scope.current_file} line 1" : "line 1"
      "Liquid error (#{location}): #{LiquidIL.clean_error_message(e.message)}"
    end

    # Save the compiled template as a standalone Ruby file
    # The generated file can be required and used independently
    def save(path)
      raise "Cannot save template that uses VM fallback" if @uses_vm
      raise "No compiled source available" unless @compiled_source

      File.write(path, generate_standalone_source)
    end

    private

    def generate_standalone_source
      # Extract the proc body from compiled source (remove the "proc do |...| ... end" wrapper)
      proc_body = extract_proc_body(@compiled_source)

      # Generate partial methods
      partial_methods = generate_partial_methods

      # Generate partial source comments
      partial_sources = @partials.map do |name, info|
        lines = ["# Partial '#{name}':"]
        lines += info[:source].lines.map { |l| "#   #{l.chomp}" }
        lines.join("\n")
      end.join("\n#\n")
      partial_sources = "\n#\n#{partial_sources}" unless partial_sources.empty?

      <<~RUBY
        # frozen_string_literal: true
        #
        # Auto-generated by LiquidIL::Compiler::Ruby
        # Original template:
        #{@source.lines.map { |l| "#   #{l}" }.join}#{partial_sources}
        #
        # Usage:
        #   require_relative 'this_file'
        #   output = render({"name" => "World"})
        #

        require "liquid_il"

        module CompiledLiquidTemplate
          extend self

          SPANS = #{@spans.inspect}.freeze
          SOURCE = #{@source.inspect}.freeze

          #{generate_helper_methods}
        #{partial_methods}
          def render(assigns = {})
            __scope__ = LiquidIL::Scope.new(assigns)
            __spans__ = SPANS
            __template_source__ = SOURCE
            __output__ = String.new
            __stack__ = []
            __for_iterators__ = []
            __current_file__ = nil

        #{indent_code(proc_body, 4)}

            __output__
          rescue LiquidIL::RuntimeError => e
            output = e.partial_output || ""
            location = e.file ? "\#{e.file} line \#{e.line}" : "line \#{e.line}"
            output + "Liquid error (\#{location}): \#{e.message}"
          end
        end

        # Convenience method at top level
        def render(assigns = {})
          CompiledLiquidTemplate.render(assigns)
        end

        # Run directly if executed as script
        if __FILE__ == $0
          require "json"
          assigns = ARGV[0] ? JSON.parse(ARGV[0]) : {}
          puts render(assigns)
        end
      RUBY
    end

    def generate_partial_methods
      return "" if @partials.empty?

      code = String.new
      @partials.each do |name, info|
        method_name = "__partial_#{name.gsub(/[^a-zA-Z0-9_]/, '_')}__"
        body = info[:compiled_body]

        code << "\n"
        code << "  # Partial: #{name}\n"
        code << "  def #{method_name}(assigns, __output__, __parent_scope__, isolated, caller_line: 1)\n"
        code << "    # Save and set file context for error reporting\n"
        code << "    __prev_file__ = __parent_scope__.current_file\n"
        code << "    __parent_scope__.current_file = #{name.inspect}\n"
        code << "\n"
        code << "    # Check render depth to prevent infinite recursion\n"
        code << "    __parent_scope__.push_render_depth\n"
        code << "    if __parent_scope__.render_depth_exceeded?(strict: !isolated)\n"
        code << "      raise LiquidIL::RuntimeError.new(\"Nesting too deep\", file: #{name.inspect}, line: caller_line)\n"
        code << "    end\n"
        code << "\n"
        code << "    __scope__ = isolated ? __parent_scope__.isolated : __parent_scope__\n"
        code << "    assigns.each { |k, v| __scope__.assign(k, v) }\n"
        code << "    __spans__ = #{info[:spans].inspect}\n"
        code << "    __template_source__ = #{info[:source].inspect}\n"
        code << "    __stack__ = []\n"
        code << "    __for_iterators__ = []\n"
        code << "    __current_file__ = #{name.inspect}\n"
        code << "\n"
        code << indent_code(body, 4)
        code << "  rescue LiquidIL::RuntimeError => e\n"
        code << "    raise unless __parent_scope__.render_errors\n"
        code << "    __write_output__(e.partial_output, __output__, __scope__) if e.partial_output\n"
        code << "    location = e.file ? \"\#{e.file} line \#{e.line}\" : \"line \#{e.line}\"\n"
        code << "    __write_output__(\"Liquid error (\#{location}): \#{e.message}\", __output__, __scope__)\n"
        code << "  rescue StandardError => e\n"
        code << "    raise unless __parent_scope__.render_errors\n"
        code << "    __write_output__(\"Liquid error (#{name} line 1): \#{LiquidIL.clean_error_message(e.message)}\", __output__, __scope__)\n"
        code << "  ensure\n"
        code << "    __parent_scope__.current_file = __prev_file__\n"
        code << "    __parent_scope__.pop_render_depth\n"
        code << "  end\n"
      end

      code
    end

    def extract_proc_body(source)
      lines = source.lines
      # Skip first line (frozen_string_literal comment) and proc declaration
      # Find the proc body between "proc do |...|\n" and the final "end\n"
      start_idx = lines.index { |l| l.match?(/^proc do \|/) }
      return "" unless start_idx

      # Skip proc declaration line
      body_lines = lines[(start_idx + 1)..]
      # Remove variable declarations that we handle in render method
      body_lines = body_lines.reject { |l| l.match?(/^\s*(__output__|__stack__|__for_iterators__|__current_file__)\s*=/) }
      # Remove the final "end\n" and "__output__\n"
      body_lines = body_lines[0...-2] if body_lines[-1]&.match?(/^end\s*$/)
      body_lines = body_lines[0...-1] if body_lines[-1]&.match?(/^\s*__output__\s*$/)

      body_lines.join
    end

    def indent_code(code, spaces)
      indent = " " * spaces
      code.lines.map { |l| l.strip.empty? ? l : "#{indent}#{l.sub(/^  /, '')}" }.join
    end

    def generate_helper_methods
      <<~'RUBY'
        def __write_output__(str, output, scope)
          return unless str
          return if scope&.has_interrupt?
          if scope&.capturing?
            scope.current_capture << str.to_s
          else
            output << str.to_s
          end
        end

        def __call_filter__(name, input, args, scope, spans, source, inst_idx, current_file = nil)
          LiquidIL::Filters.apply(name, input, args, scope)
        rescue LiquidIL::FilterError
          nil
        rescue LiquidIL::FilterRuntimeError => e
          line = __compute_line__(spans, source, inst_idx)
          if scope.render_errors
            location = current_file ? "#{current_file} line #{line}" : "line #{line}"
            LiquidIL::ErrorMarker.new(e.message, location)
          else
            raise LiquidIL::RuntimeError.new(e.message, file: current_file, line: line)
          end
        end

        def __compute_line__(spans, source, inst_idx)
          return 1 unless spans && source && inst_idx
          span = spans[inst_idx]
          return 1 unless span
          pos = span[0] || 0
          source[0, pos].count("\n") + 1
        end

        def __compare_with_error__(left, right, op, output, scope, current_file = nil)
          __compare__(left, right, op)
        rescue ArgumentError => e
          location = current_file ? "#{current_file} line 1" : "line 1"
          __write_output__("Liquid error (#{location}): #{e.message}", output, scope)
          false
        end

        def __new_range__(start_val, end_val, output, scope, current_file = nil)
          if start_val.is_a?(Float) || end_val.is_a?(Float)
            location = current_file ? "#{current_file} line 1" : "line 1"
            return LiquidIL::ErrorMarker.new("invalid integer", location)
          end
          LiquidIL::RangeValue.new(start_val, end_val)
        end

        def __is_truthy__(value)
          # Fast path for common types that don't have to_liquid_value
          case value
          when nil, false, LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral
            false
          when true, String, Integer, Float, Array, Hash
            true
          else
            value = value.to_liquid_value if value.respond_to?(:to_liquid_value)
            !value.nil? && value != false
          end
        end

        def __is_collection_empty__(value)
          case value
          when nil then true
          when Array, Hash, String then value.empty?
          when LiquidIL::RangeValue then value.length <= 0
          else
            __to_iterable__(value).empty?
          end
        end

        def __lookup_key__(obj, key)
          return nil if obj.nil?
          # Fast path: strings/integers don't have to_liquid_value
          key = key.to_liquid_value if !key.is_a?(String) && !key.is_a?(Integer) && key.respond_to?(:to_liquid_value)
          return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)

          case obj
          when Hash
            result = obj[key]
            return result unless result.nil?
            result = obj[key.to_s]
            return result unless result.nil?
            obj[key.to_sym] if key.is_a?(String)
          when Array
            if key.is_a?(Integer)
              obj[key]
            elsif key.to_s =~ /\A-?\d+\z/
              obj[key.to_i]
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop
            obj[key]
          when String
            if key.is_a?(Integer)
              obj[key]
            elsif key.to_s =~ /\A-?\d+\z/
              obj[key.to_i]
            end
          else
            obj[key] if obj.respond_to?(:[])
          end
        end

        def __lookup_property__(obj, key)
          return nil if obj.nil?
          # Fast path: strings don't have to_liquid_value
          key = key.to_liquid_value if !key.is_a?(String) && key.respond_to?(:to_liquid_value)

          case obj
          when Hash
            # Fast path: key is usually already a string
            key_str = key.is_a?(String) ? key : key.to_s
            result = obj[key_str]
            return result unless result.nil?
            result = obj[key_str.to_sym]
            return result unless result.nil?
            case key_str
            when "first"
              pair = obj.first
              pair ? "#{pair[0]}#{pair[1]}" : nil
            when "size", "length"
              obj.length
            end
          when Array
            if key.is_a?(Integer)
              obj[key]
            else
              case key.to_s
              when "size", "length" then obj.length
              when "first" then obj.first
              when "last" then obj.last
              else obj[key.to_i]
              end
            end
          when LiquidIL::ForloopDrop, LiquidIL::Drop
            obj[key]
          when LiquidIL::RangeValue
            case key.to_s
            when "first" then obj.first
            when "last" then obj.last
            when "size", "length" then obj.length
            end
          when String
            case key.to_s
            when "size", "length" then obj.length
            when "first" then obj[0]
            when "last" then obj[-1]
            end
          when Integer
            obj.size if key.to_s == "size"
          when Float
            nil
          else
            if key.is_a?(String) && obj.respond_to?(key.to_sym)
              obj.send(key.to_sym)
            elsif obj.respond_to?(:[])
              obj[key.to_s]
            end
          end
        end

        # Optimized path lookup - inline Hash fast path, single method call for chains
        def __lookup_path__(obj, *keys)
          keys.each do |k|
            return nil if obj.nil?
            if obj.is_a?(Hash)
              # Fast path: Hash is most common
              result = obj[k]
              obj = result.nil? ? obj[k.to_sym] : result
            else
              obj = __lookup_property__(obj, k)
            end
          end
          obj
        end

        def __execute_command__(obj, command)
          case command
          when "size", "length"
            case obj
            when Array, String, Hash then obj.length
            when LiquidIL::RangeValue then obj.length
            else obj.length if obj.respond_to?(:length)
            end
          when "first"
            case obj
            when Array then obj.first
            when LiquidIL::RangeValue then obj.start_val
            end
          when "last"
            case obj
            when Array then obj.last
            when LiquidIL::RangeValue then obj.end_val
            end
          end
        end

        def __compare__(left, right, op)
          left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
          right = right.to_liquid_value if right.respond_to?(:to_liquid_value)
          left = LiquidIL::RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
          right = LiquidIL::RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

          if right.is_a?(LiquidIL::EmptyLiteral)
            return false if left.is_a?(LiquidIL::EmptyLiteral) || left.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(left) if op == :eq
            return !__is_empty__(left) if op == :ne
          end
          if right.is_a?(LiquidIL::BlankLiteral)
            return false if left.is_a?(LiquidIL::EmptyLiteral) || left.is_a?(LiquidIL::BlankLiteral)
            return __is_blank__(left) if op == :eq
            return !__is_blank__(left) if op == :ne
          end
          if left.is_a?(LiquidIL::EmptyLiteral)
            return __is_empty__(right) if op == :eq
            return !__is_empty__(right) if op == :ne
          end
          if left.is_a?(LiquidIL::BlankLiteral)
            return __is_blank__(right) if op == :eq
            return !__is_blank__(right) if op == :ne
          end

          case op
          when :eq then left == right
          when :ne then left != right
          when :lt then __compare_numeric__(left, right, :lt)
          when :le then __compare_numeric__(left, right, :le)
          when :gt then __compare_numeric__(left, right, :gt)
          when :ge then __compare_numeric__(left, right, :ge)
          else false
          end
        end

        def __case_compare__(left, right)
          left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
          right = right.to_liquid_value if right.respond_to?(:to_liquid_value)
          left = LiquidIL::RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
          right = LiquidIL::RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

          if left.is_a?(LiquidIL::BlankLiteral) || left.is_a?(LiquidIL::EmptyLiteral)
            return __is_blank_strict__(right) if left.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(right) if left.is_a?(LiquidIL::EmptyLiteral)
          end
          if right.is_a?(LiquidIL::BlankLiteral) || right.is_a?(LiquidIL::EmptyLiteral)
            return __is_blank__(left) if right.is_a?(LiquidIL::BlankLiteral)
            return __is_empty__(left) if right.is_a?(LiquidIL::EmptyLiteral)
          end
          left == right
        end

        def __is_empty__(value)
          case value
          when LiquidIL::EmptyLiteral then true
          when String, Array, Hash then value.empty?
          else false
          end
        end

        def __is_blank__(value)
          case value
          when LiquidIL::BlankLiteral, nil, false then true
          when String then value.empty? || value.strip.empty?
          when Array, Hash then value.empty?
          else false
          end
        end

        def __is_blank_strict__(value)
          case value
          when LiquidIL::BlankLiteral, nil, false then true
          when String then value.empty?
          when Array, Hash then value.empty?
          else false
          end
        end

        def __compare_numeric__(left, right, op)
          return false if left.nil? || right.nil?
          return false if left == true || left == false || right == true || right == false
          return false if left.is_a?(Array) || left.is_a?(Hash) || right.is_a?(Array) || right.is_a?(Hash)
          return false if left.is_a?(LiquidIL::RangeValue) || right.is_a?(LiquidIL::RangeValue)

          left_num = __to_number__(left)
          right_num = __to_number__(right)
          if left_num.nil? || right_num.nil?
            right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
            raise ArgumentError, "comparison of #{left.class} with #{right_str} failed"
          end

          case op
          when :lt then left_num < right_num
          when :le then left_num <= right_num
          when :gt then left_num > right_num
          when :ge then left_num >= right_num
          else false
          end
        end

        def __to_number__(value)
          case value
          when Integer, Float then value
          when String
            if value =~ /\A-?\d+\z/
              value.to_i
            elsif value =~ /\A-?\d+\.\d+\z/
              value.to_f
            end
          end
        end

        def __contains__(left, right)
          return false if right.nil?
          case left
          when String
            right_str = right.to_s
            if left.encoding != right_str.encoding
              begin
                left = left.dup.force_encoding(Encoding::UTF_8)
                right_str = right_str.dup.force_encoding(Encoding::UTF_8)
              rescue
                return false
              end
            end
            left.include?(right_str) rescue false
          when Array then left.include?(right)
          when Hash then left.key?(right.to_s) || (right.is_a?(String) && left.key?(right.to_sym))
          else false
          end
        end

        def __cycle_step__(identity, values, scope)
          resolved = values.map do |v|
            if v.is_a?(Array) && v.length == 2
              type, val = v
              if type == :lit
                val
              elsif type == :var
                scope.lookup(val)
              else
                val
              end
            else
              v
            end
          end
          scope.cycle_step(identity, resolved)
        end

        def __to_iterable__(value)
          case value
          when nil, true, false, Integer, Float then []
          when String then value.empty? ? [] : [value]
          when LiquidIL::RangeValue then value.to_a
          when Array then value
          when Hash then value.map { |k, v| [k, v] }
          else
            if value.respond_to?(:to_a)
              value.to_a rescue (value.respond_to?(:each) ? value.to_enum.to_a : [])
            elsif value.respond_to?(:each)
              value.to_enum.to_a
            else
              []
            end
          end
        end

        def __eval_expression__(expr, scope)
          return nil unless expr
          expr_str = expr.to_s

          # Handle string literals (quoted strings)
          if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
            return Regexp.last_match(1)
          end

          # Handle range literals (1..10)
          if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
            return LiquidIL::RangeValue.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
          end

          # Parse variable path: product.name or items[0]
          parts = expr_str.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
          return nil if parts.empty?

          result = nil
          parts.each_with_index do |match, idx|
            if idx == 0
              # First part is always a variable name
              result = scope.lookup(match[0])
            else
              # Subsequent parts are property access
              key = match[0] || match[1] || match[2]
              result = __lookup_property__(result, key.to_s =~ /^\d+$/ ? key.to_i : key)
            end
          end
          result
        end

        def __valid_integer__(value)
          return true if value.nil? || value.is_a?(Integer) || value.is_a?(Float)
          return true if value.is_a?(String) && value =~ /\A-?\d/
          false
        end

        def __to_integer__(value)
          num = __to_number__(value)
          num ? num.to_i : 0
        end

        def __create_iterator__(collection, loop_name, has_limit, limit, has_offset, offset, offset_continue, reversed, scope, output)
          is_nil_collection = collection.nil? || collection == false
          is_string_collection = collection.is_a?(String)
          items = __to_iterable__(collection)

          unless is_nil_collection
            if has_limit && !__valid_integer__(limit)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::ForIterator.new([], loop_name, start_offset: 0, offset_continue: false)
            end
            if has_offset && !__valid_integer__(offset)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::ForIterator.new([], loop_name, start_offset: 0, offset_continue: false)
            end
          end

          from = 0
          if offset_continue
            from = scope.for_offset(loop_name)
          elsif !offset.nil?
            from = __to_integer__(offset)
          end

          to = nil
          if !limit.nil?
            limit_val = __to_integer__(limit)
            to = from + limit_val
          end

          items = __slice_collection__(items, from, to, is_string: is_string_collection)
          items = items.reverse if reversed
          actual_offset = [from, 0].max

          LiquidIL::ForIterator.new(items, loop_name, start_offset: actual_offset, offset_continue: offset_continue)
        end

        def __slice_collection__(collection, from, to, is_string: false)
          return collection if is_string
          segments = []
          index = 0
          collection.each do |item|
            break if to && to <= index
            segments << item if from <= index
            index += 1
          end
          segments
        end

        def __create_tablerow_iterator__(collection, loop_name, has_limit, limit, has_offset, offset, cols, cols_type, scope, output)
          is_nil_collection = collection.nil? || collection == false
          is_string_collection = collection.is_a?(String)
          items = __to_iterable__(collection)

          cols_explicit_nil = false
          case cols_type
          when :explicit_nil
            cols_explicit_nil = true
            cols = items.length
          when :dynamic
            if cols.nil?
              cols_explicit_nil = true
              cols = items.length
            elsif cols.is_a?(Integer)
              # Keep as is
            elsif cols.is_a?(Float)
              cols = cols.to_i
            elsif cols.is_a?(String) && cols =~ /\A-?\d+(?:\.\d+)?\z/
              cols = cols.to_i
            elsif !is_nil_collection
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: 1, skip_output: true)
            end
          when :default
            cols = items.length
          when :static
            # Keep as is
          end

          unless is_nil_collection
            if has_limit && !__valid_integer__(limit)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: cols || 1, skip_output: true)
            end
            if has_offset && !__valid_integer__(offset)
              __write_output__("Liquid error (line 1): invalid integer", output, scope)
              return LiquidIL::TablerowIterator.new([], loop_name, cols: cols || 1, skip_output: true)
            end
          end

          if has_offset && !is_string_collection
            start_offset = offset.nil? ? 0 : __to_integer__(offset)
            start_offset = [start_offset, 0].max
            items = items.drop(start_offset) if start_offset > 0
          end

          if has_limit && limit.nil? && !is_string_collection
            items = []
          elsif has_limit && !is_string_collection
            limit_val = __to_integer__(limit)
            limit_val = [limit_val, 0].max
            items = items.take(limit_val)
          end

          LiquidIL::TablerowIterator.new(items, loop_name, cols: cols, skip_output: is_nil_collection, cols_explicit_nil: cols_explicit_nil)
        end

        def __tablerow_output_tags__(iter, output, scope)
          return if iter.skip_output
          if iter.index0 > 0
            __write_output__("</td>", output, scope)
            if iter.at_row_end?
              __write_output__("</tr>\n", output, scope)
            end
          end

          if iter.at_row_start?
            if iter.row == 1
              __write_output__("<tr class=\"row#{iter.row}\">\n", output, scope)
            else
              __write_output__("<tr class=\"row#{iter.row}\">", output, scope)
            end
          end
          __write_output__("<td class=\"col#{iter.col}\">", output, scope)
        end

        def __tablerow_close_tags__(iter, output, scope)
          return unless iter && !iter.skip_output
          if iter.index0 > 0
            __write_output__("</td>", output, scope)
            __write_output__("</tr>\n", output, scope)
          elsif iter.index0 == 0
            __write_output__("</tr>\n", output, scope)
          end
        end
      RUBY
    end
  end

  class Compiler
    # AOT Ruby compiler entry point
    module Ruby
      def self.compile(template_or_source, context: nil, **options)
        # Accept either a Template object or a source string
        if template_or_source.is_a?(LiquidIL::Template)
          template = template_or_source
          source = template.source
          instructions = template.instructions
          spans = template.spans
          context ||= template.instance_variable_get(:@context)
        else
          source = template_or_source
          compiler = Compiler.new(source, **options.merge(optimize: true))
          result = compiler.compile
          instructions = result[:instructions]
          spans = result[:spans]
        end

        # Try to compile to Ruby, passing context for partial resolution
        ruby_compiler = RubyCompiler.new(
          instructions,
          spans: spans,
          template_source: source,
          context: context
        )
        compiled_result = ruby_compiler.compile

        CompiledTemplate.new(source, instructions, spans, context, compiled_result)
      end
    end
  end
end
