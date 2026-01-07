# frozen_string_literal: true

module LiquidIL
  # Compiles IL instructions to Ruby code for AOT execution.
  # Falls back to VM for unsupported instructions.
  class RubyCompiler
    UNSUPPORTED_OPCODES = [
      IL::RENDER_PARTIAL,
      IL::INCLUDE_PARTIAL,
    ].freeze

    class CompilationResult
      attr_reader :proc, :source, :can_compile

      def initialize(proc:, source:, can_compile:)
        @proc = proc
        @source = source
        @can_compile = can_compile
      end
    end

    def initialize(instructions, spans: nil, template_source: nil)
      @instructions = instructions
      @spans = spans
      @template_source = template_source
      @var_counter = 0
      @label_to_block = {}  # label_id -> block index where label appears
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
        can_compile: true
      )
    end

    private

    def can_compile?
      @instructions.each do |inst|
        return false if UNSUPPORTED_OPCODES.include?(inst[0])
      end
      true
    end

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

    def generate_ruby(structured)
      code = String.new
      code << "# frozen_string_literal: true\n"
      code << "proc do |__scope__, __spans__, __template_source__|\n"
      code << "  __output__ = String.new\n"
      code << "  __stack__ = []\n"
      code << "  __for_iterators__ = []\n"
      code << "  __current_file__ = nil\n"
      code << "\n"

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
        code << generate_state_machine(blocks)
      else
        code << generate_straight_line(blocks)
      end

      code << "\n  __output__\n"
      code << "end\n"

      code
    end

    def generate_straight_line(blocks)
      code = String.new

      blocks.each do |block|
        block.instructions.each_with_index do |inst, local_idx|
          code << generate_instruction(inst, block.indices[local_idx])
        end
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

        block.instructions.each_with_index do |inst, local_idx|
          global_idx = block.indices[local_idx]
          inst_code = generate_instruction_for_state_machine(inst, global_idx, block)
          code << inst_code
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
      when IL::WRITE_RAW
        "  __write_output__(#{inst[1].inspect}, __output__, __scope__)\n"
      when IL::WRITE_VALUE
        "  __v__ = __stack__.pop; __write_output__(__v__.is_a?(LiquidIL::ErrorMarker) ? __v__.to_s : LiquidIL::Utils.output_string(__v__), __output__, __scope__)\n"
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
        "  __obj__ = __scope__.lookup(#{name.inspect}); #{path.map { |k| "__obj__ = __lookup_property__(__obj__, #{k.inspect})" }.join("; ")}; __stack__ << __obj__\n"
      when IL::LOOKUP_KEY
        "  __k__ = __stack__.pop; __o__ = __stack__.pop; __stack__ << __lookup_key__(__o__, __k__)\n"
      when IL::LOOKUP_CONST_KEY
        "  __stack__ << __lookup_property__(__stack__.pop, #{inst[1].inspect})\n"
      when IL::LOOKUP_CONST_PATH
        path = inst[1]
        "  __obj__ = __stack__.pop; #{path.map { |k| "__obj__ = __lookup_property__(__obj__, #{k.inspect})" }.join("; ")}; __stack__ << __obj__\n"
      when IL::LOOKUP_COMMAND
        "  __stack__ << __execute_command__(__stack__.pop, #{inst[1].inspect})\n"
      when IL::PUSH_CAPTURE
        "  __scope__.push_capture\n"
      when IL::POP_CAPTURE
        "  __stack__ << __scope__.pop_capture\n"
      when IL::COMPARE
        "  __r__ = __stack__.pop; __l__ = __stack__.pop; __stack__ << __compare_with_error__(__l__, __r__, #{inst[1].inspect}, __output__, __scope__)\n"
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
        "  __e__ = __stack__.pop; __s__ = __stack__.pop; __stack__ << __new_range__(__s__, __e__, __output__, __scope__)\n"
      when IL::CALL_FILTER
        "  __args__ = __stack__.pop(#{inst[2]}); __input__ = __stack__.pop; __stack__ << __call_filter__(#{inst[1].inspect}, __input__, __args__, __scope__, __spans__, __template_source__, #{idx})\n"
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
        "  __scope__.store_temp(#{inst[1]}, __stack__.pop)\n"
      when IL::LOAD_TEMP
        "  __stack__ << __scope__.load_temp(#{inst[1]})\n"
      when IL::IFCHANGED_CHECK
        "  __captured__ = __stack__.pop; __prev__ = __scope__.get_ifchanged_state(#{inst[1].inspect}); if __captured__ != __prev__; __scope__.set_ifchanged_state(#{inst[1].inspect}, __captured__); __output__ << __captured__.to_s; end\n"
      when IL::PUSH_INTERRUPT
        "  __scope__.push_interrupt(#{inst[1].inspect})\n"
      when IL::POP_INTERRUPT
        "  __scope__.pop_interrupt\n"
      when IL::PUSH_FORLOOP
        <<~RUBY
          __iter__ = __for_iterators__.last
          __parent__ = __scope__.current_forloop
          __forloop__ = LiquidIL::ForloopDrop.new(__iter__&.name || "", __iter__&.length || 0, __parent__)
          __scope__.push_forloop(__forloop__)
          __scope__.assign_local("forloop", __forloop__)
        RUBY
      when IL::POP_FORLOOP
        "  __scope__.pop_forloop\n"
      else
        "  # unsupported: #{opcode}\n"
      end
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
      when IL::FOR_INIT
        var_name, loop_name, has_limit, has_offset, offset_continue, reversed, recovery_label = inst[1..]
        recovery_target = recovery_label ? @label_to_block[recovery_label] : "(__pc__ = #{block.id + 1}; break)"
        <<~RUBY
              __offset__ = #{has_offset} ? __stack__.pop : nil
              __limit__ = #{has_limit} ? __stack__.pop : nil
              __coll__ = __stack__.pop
              __iter__ = __create_iterator__(__coll__, #{loop_name.inspect}, #{has_limit}, __limit__, #{has_offset}, __offset__, #{offset_continue}, #{reversed}, __scope__, __output__)
              __for_iterators__ << __iter__
        RUBY
      when IL::FOR_NEXT
        continue_label, break_label = inst[1], inst[2]
        continue_target = @label_to_block[continue_label]
        break_target = @label_to_block[break_label]
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
          return if scope.has_interrupt?
          if scope.capturing?
            scope.current_capture << str.to_s
          else
            output << str.to_s
          end
        end

        def __call_filter__(name, input, args, scope, spans, source, inst_idx)
          LiquidIL::Filters.apply(name, input, args, scope)
        rescue LiquidIL::FilterError
          # Filter error in non-strict mode - push nil so ASSIGN assigns nil
          nil
        rescue LiquidIL::FilterRuntimeError => e
          # Filter runtime error - push ErrorMarker with correct line number
          line = __compute_line__(spans, source, inst_idx)
          LiquidIL::ErrorMarker.new(e.message, "line #{line}")
        end

        def __compute_line__(spans, source, inst_idx)
          return 1 unless spans && source && inst_idx
          span = spans[inst_idx]
          return 1 unless span
          pos = span[0] || 0
          source[0, pos].count("\n") + 1
        end

        def __compare_with_error__(left, right, op, output, scope)
          __compare__(left, right, op)
        rescue ArgumentError => e
          __write_output__("Liquid error (line 1): #{e.message}", output, scope)
          false
        end

        def __new_range__(start_val, end_val, output, scope)
          if start_val.is_a?(Float) || end_val.is_a?(Float)
            return LiquidIL::ErrorMarker.new("invalid integer", "line 1")
          end
          LiquidIL::RangeValue.new(start_val, end_val)
        end

        def __is_truthy__(value)
          value = value.to_liquid_value if value.respond_to?(:to_liquid_value)
          case value
          when nil, false, LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral
            false
          else
            true
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
          key = key.to_liquid_value if key.respond_to?(:to_liquid_value)
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
          key = key.to_liquid_value if key.respond_to?(:to_liquid_value)

          case obj
          when Hash
            key_str = key.to_s
            result = obj[key_str]
            return result unless result.nil?
            result = obj[key.to_sym] if key.is_a?(String)
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
            elsif key.to_s =~ /\A-?\d+\z/
              obj[key.to_i]
            elsif key.to_s == "size" || key.to_s == "length"
              obj.length
            elsif key.to_s == "first"
              obj.first
            elsif key.to_s == "last"
              obj.last
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

      # Create proc with helpers in scope
      binding_obj = helpers.instance_eval { binding }
      eval(source, binding_obj)
    rescue SyntaxError, StandardError => e
      nil
    end
  end

  # A compiled template that uses the generated Ruby proc
  class CompiledTemplate
    attr_reader :source, :instructions, :spans, :compiled_source, :uses_vm

    def initialize(source, instructions, spans, context, compiled_result)
      @source = source
      @instructions = instructions
      @spans = spans
      @context = context
      @compiled_proc = compiled_result.proc
      @compiled_source = compiled_result.source
      @uses_vm = !compiled_result.can_compile
    end

    def render(assigns = {}, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = Scope.new(assigns, registers: @context&.registers&.dup || {}, strict_errors: @context&.strict_errors || false)
      scope.file_system = @context&.file_system

      if @uses_vm
        # Fall back to VM
        VM.execute(@instructions, scope, spans: @spans, source: @source)
      else
        # Use compiled proc
        @compiled_proc.call(scope, @spans, @source)
      end
    rescue LiquidIL::RuntimeError => e
      output = e.partial_output || ""
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output + "Liquid error (#{location}): #{e.message}"
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

        # Try to compile to Ruby
        ruby_compiler = RubyCompiler.new(instructions, spans: spans, template_source: source)
        compiled_result = ruby_compiler.compile

        CompiledTemplate.new(source, instructions, spans, context, compiled_result)
      end
    end
  end
end
