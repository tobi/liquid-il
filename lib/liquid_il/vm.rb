# frozen_string_literal: true

require_relative "utils"

module LiquidIL
  class ErrorMarker
    attr_reader :message, :location
    def initialize(message, location)
      @message = message
      @location = location
    end
    def to_s
      "Liquid error (#{@location}): #{@message}"
    end
  end

  # Strip "Liquid error: " prefix from error messages to avoid double-wrapping
  # This handles Liquid::StandardError which has message format "Liquid error: ..."
  def self.clean_error_message(message)
    message.to_s.sub(/\ALiquid error: /i, "")
  end

  # Virtual Machine - executes IL instructions
  class VM
    class << self
      def execute(instructions, context, current_file: nil, spans: nil, source: nil)
        vm = new(instructions, context, current_file: current_file, spans: spans, source: source)
        vm.run
      end
    end

    # Default output buffer capacity (8KB)
    OUTPUT_CAPACITY = 8192

    # Fixed register file size - pre-allocated for fast access
    REGISTER_COUNT = 16

    def initialize(instructions, context, current_file: nil, spans: nil, source: nil)
      @instructions = instructions
      @context = context
      @stack = []
      @output = String.new(capacity: OUTPUT_CAPACITY)
      @pc = 0  # Program counter
      @for_iterators = []  # Stack of iterators for FOR_NEXT
      @current_file = current_file  # Current file name for error messages
      @spans = spans  # Source spans for line tracking
      @source = source  # Source code for line counting
      @regs = Array.new(REGISTER_COUNT)  # Fixed register file for value caching
    end

    # Raise a runtime error with the current file context and line number
    def raise_error(message)
      line = current_line
      err = LiquidIL::RuntimeError.new(message, file: @current_file, line: line)
      raise err
    end

    # Get the current line number based on PC and spans
    def current_line
      return 1 unless @spans && @source
      span = @spans[@pc]
      return 1 unless span
      # Count newlines before the span start position
      pos = span[0]
      @source[0, pos].count("\n") + 1
    end

    def run
      while @pc < @instructions.length
        inst = @instructions[@pc]
        opcode = inst[0]

        case opcode
        when IL::HALT
          break

        when IL::WRITE_RAW
          write_output(inst[1])
          @pc += 1

        when IL::WRITE_VALUE
          value = @stack.pop
          if value.is_a?(ErrorMarker)
            write_output(value.to_s)
          else
            write_output(to_output(value))
          end
          @pc += 1

        when IL::WRITE_VAR
          # Fused FIND_VAR + WRITE_VALUE (no stack needed)
          value = @context.lookup(inst[1])
          write_output(to_output(value))
          @pc += 1

        when IL::WRITE_VAR_PATH
          # Fused FIND_VAR_PATH + WRITE_VALUE (no stack needed)
          obj = @context.lookup(inst[1])
          inst[2].each do |key|
            obj = lookup_property(obj, key)
            break if obj.nil?
          end
          write_output(to_output(obj))
          @pc += 1

        when IL::CONST_NIL
          @stack.push(nil)
          @pc += 1

        when IL::CONST_TRUE
          @stack.push(true)
          @pc += 1

        when IL::CONST_FALSE
          @stack.push(false)
          @pc += 1

        when IL::CONST_INT
          @stack.push(inst[1])
          @pc += 1

        when IL::CONST_FLOAT
          @stack.push(inst[1])
          @pc += 1

        when IL::CONST_STRING
          @stack.push(inst[1])
          @pc += 1

        when IL::CONST_RANGE
          @stack.push(RangeValue.new(inst[1], inst[2]))
          @pc += 1

        when IL::CONST_EMPTY
          @stack.push(EmptyLiteral.instance)
          @pc += 1

        when IL::CONST_BLANK
          @stack.push(BlankLiteral.instance)
          @pc += 1

        when IL::FIND_VAR
          name = inst[1]
          value = @context.lookup(name)
          @stack.push(value)
          @pc += 1

        when IL::FIND_VAR_PATH
          name = inst[1]
          path = inst[2]
          obj = @context.lookup(name)
          path.each do |key|
            obj = lookup_property(obj, key)
            break if obj.nil?
          end
          @stack.push(obj)
          @pc += 1

        when IL::FIND_VAR_DYNAMIC
          name = @stack.pop
          value = @context.lookup(name.to_s)
          @stack.push(value)
          @pc += 1

        when IL::LOOKUP_KEY
          key = @stack.pop
          obj = @stack.pop
          @stack.push(lookup_key_only(obj, key))
          @pc += 1

        when IL::LOOKUP_CONST_KEY
          key = inst[1]
          obj = @stack.pop
          @stack.push(lookup_property(obj, key))
          @pc += 1

        when IL::LOOKUP_CONST_PATH
          path = inst[1]
          obj = @stack.pop
          path.each do |key|
            obj = lookup_property(obj, key)
            break if obj.nil?
          end
          @stack.push(obj)
          @pc += 1

        when IL::LOOKUP_COMMAND
          command = inst[1]
          obj = @stack.pop
          @stack.push(execute_command(obj, command))
          @pc += 1

        when IL::PUSH_CAPTURE
          @context.push_capture
          @pc += 1

        when IL::POP_CAPTURE
          captured = @context.pop_capture
          @stack.push(captured)
          @pc += 1

        when IL::LABEL
          # Labels are no-ops at runtime (used only for linking)
          @pc += 1

        when IL::JUMP
          @pc = inst[1]

        when IL::JUMP_IF_FALSE
          value = @stack.pop
          if !is_truthy(value)
            @pc = inst[1]
          else
            @pc += 1
          end

        when IL::JUMP_IF_TRUE
          value = @stack.pop
          if is_truthy(value)
            @pc = inst[1]
          else
            @pc += 1
          end

        when IL::JUMP_IF_EMPTY
          value = @stack.last  # peek, don't pop
          if is_collection_empty(value)
            @stack.pop
            @pc = inst[1]
          else
            @pc += 1
          end

        when IL::JUMP_IF_INTERRUPT
          if @context.has_interrupt?
            interrupt = @context.pop_interrupt
            if interrupt == :continue
              @pc += 1
            else
              @pc = inst[1]
            end
          else
            @pc += 1
          end

        when IL::COMPARE
          op = inst[1]
          right = @stack.pop
          left = @stack.pop
          begin
            @stack.push(compare(left, right, op))
          rescue ArgumentError => e
            # Output comparison error and push false
            location = @current_file ? "#{@current_file} line #{current_line}" : "line #{current_line}"
            write_output("Liquid error (#{location}): #{e.message}")
            @stack.push(false)
          end
          @pc += 1

        when IL::CASE_COMPARE
          # Case/when comparison with stricter blank/empty handling
          right = @stack.pop  # when value
          left = @stack.pop   # case value
          @stack.push(case_compare(left, right))
          @pc += 1

        when IL::CONTAINS
          right = @stack.pop
          left = @stack.pop
          @stack.push(contains(left, right))
          @pc += 1

        when IL::BOOL_NOT
          value = @stack.pop
          @stack.push(!is_truthy(value))
          @pc += 1

        when IL::IS_TRUTHY
          value = @stack.pop
          @stack.push(is_truthy(value))
          @pc += 1

        when IL::PUSH_SCOPE
          @context.push_scope
          @pc += 1

        when IL::POP_SCOPE
          @context.pop_scope
          @pc += 1

        when IL::ASSIGN
          name = inst[1]
          value = @stack.pop
          @context.assign(name, value) unless value.is_a?(ErrorMarker)
          @pc += 1

        when IL::ASSIGN_LOCAL
          name = inst[1]
          value = @stack.pop
          @context.assign_local(name, value) unless value.is_a?(ErrorMarker)
          @pc += 1

        when IL::NEW_RANGE
          end_val = @stack.pop
          start_val = @stack.pop
          # Validate range bounds - floats are not allowed
          if start_val.is_a?(Float) || end_val.is_a?(Float)
            raise_error "invalid integer"
          end
          @stack.push(RangeValue.new(start_val, end_val))
          @pc += 1

        when IL::CALL_FILTER
          name = inst[1]
          argc = inst[2]
          args = @stack.pop(argc)
          input = @stack.pop
          begin
            result = Filters.apply(name, input, args, @context)
            @stack.push(result)
          rescue FilterError
            # Filter error in non-strict mode - push nil so ASSIGN assigns nil
            @stack.push(nil)
          rescue FilterRuntimeError => e
            # Filter runtime error - push ErrorMarker
            location = @current_file ? "#{@current_file} line #{current_line}" : "line #{current_line}"
            @stack.push(ErrorMarker.new(e.message, location))
          end
          @pc += 1

        when IL::FOR_INIT
          var_name = inst[1]
          loop_name = inst[2]
          has_limit = inst[3]
          has_offset = inst[4]
          offset_continue = inst[5]
          reversed = inst[6]
          recovery_label = inst[7]
          # IL emits: offset, limit (in that order) so limit is on top of stack
          limit = has_limit ? @stack.pop : nil
          offset = has_offset ? @stack.pop : nil
          collection = @stack.pop
          begin
            iterator = create_iterator(collection, loop_name, has_limit, limit, has_offset, offset, offset_continue, reversed)
            @for_iterators.push(iterator)
            @pc += 1
          rescue LiquidIL::RuntimeError => e
            raise unless @context.render_errors
            # Error recovery: output error message and jump to recovery point
            location = @current_file ? "#{@current_file} line #{e.line}" : "line #{e.line}"
            @output << "Liquid error (#{location}): #{e.message}"
            @pc = recovery_label || (@instructions.length - 1)
          end

        when IL::FOR_NEXT
          label_continue = inst[1]
          label_break = inst[2]
          iterator = @for_iterators.last
          forloop = @context.current_forloop
          # Update forloop.index0 to reflect completed iterations BEFORE checking has_next
          # This ensures escaped forloop references show the final index after loop ends
          if forloop && iterator
            forloop.index0 = iterator.index0
          end
          if iterator && iterator.has_next?
            value = iterator.next_value
            @stack.push(value)
            @pc += 1
          else
            @pc = label_break
          end

        when IL::FOR_END
          iterator = @for_iterators.pop
          @context.set_for_offset(iterator.name, iterator.next_offset) if iterator
          @pc += 1

        when IL::PUSH_FORLOOP
          iterator = @for_iterators.last
          parent = @context.current_forloop
          forloop = ForloopDrop.new(iterator&.name || "", iterator&.length || 0, parent)
          @context.push_forloop(forloop)
          @context.assign_local("forloop", forloop)
          @pc += 1

        when IL::POP_FORLOOP
          @context.pop_forloop
          @pc += 1

        when IL::PUSH_INTERRUPT
          type = inst[1]
          @context.push_interrupt(type)
          @pc += 1

        when IL::POP_INTERRUPT
          @context.pop_interrupt
          @pc += 1

        when IL::INCREMENT
          name = inst[1]
          value = @context.increment(name)
          @stack.push(value)
          @pc += 1

        when IL::DECREMENT
          name = inst[1]
          value = @context.decrement(name)
          @stack.push(value)
          @pc += 1

        when IL::CYCLE_STEP
          identity = inst[1]
          values = inst[2]
          # Resolve tagged values: [:lit, val] or [:var, name]
          resolved = resolve_cycle_values(values)
          result = @context.cycle_step(identity, resolved)
          @stack.push(result)
          @pc += 1

        when IL::CYCLE_STEP_VAR
          var_name = inst[1]
          values = inst[2]
          # Look up the variable value to use as the identity
          identity = @context.lookup(var_name)
          identity = to_output(identity)
          # Resolve tagged values
          resolved = resolve_cycle_values(values)
          result = @context.cycle_step(identity, resolved)
          @stack.push(result)
          @pc += 1

        when IL::RENDER_PARTIAL
          name = inst[1]
          args = inst[2]
          render_partial(name, args, isolated: true)
          @pc += 1

        when IL::INCLUDE_PARTIAL
          name = inst[1]
          args = inst[2]
          if @context.disable_include
            # Include is not allowed inside render tag
            write_output("Liquid error (#{@current_file || 'line'} line 1): include usage is not allowed in this context")
          else
            render_partial(name, args, isolated: false)
          end
          @pc += 1
          # If include set an interrupt, skip to the next JUMP_IF_INTERRUPT
          # This allows break/continue to propagate through include
          if @context.has_interrupt?
            while @pc < @instructions.length
              break if @instructions[@pc][0] == IL::JUMP_IF_INTERRUPT
              @pc += 1
            end
            next  # Re-enter the loop to process JUMP_IF_INTERRUPT without hitting the break check
          end

        when IL::DUP
          @stack.push(@stack.last)
          @pc += 1

        when IL::POP
          @stack.pop
          @pc += 1

        when IL::BUILD_HASH
          count = inst[1]
          pairs = @stack.pop(count * 2)
          hash = {}
          i = 0
          while i < pairs.length
            key = pairs[i]
            value = pairs[i + 1]
            hash[key.to_s] = value
            i += 2
          end
          @stack.push(hash)
          @pc += 1

        when IL::TABLEROW_INIT
          var_name = inst[1]
          loop_name = inst[2]
          has_limit = inst[3]
          has_offset = inst[4]
          cols = inst[5]
          # Pop dynamic cols from stack if needed (pushed after offset)
          if cols == :dynamic
            cols_value = @stack.pop
            # Convert to integer if numeric, validate otherwise
            cols = if cols_value.nil?
                     :explicit_nil  # Variable evaluates to nil -> col_last always false
                   elsif cols_value.is_a?(Integer)
                     cols_value
                   elsif cols_value.is_a?(Float)
                     cols_value.to_i
                   elsif cols_value.is_a?(String) && cols_value =~ /\A-?\d+(?:\.\d+)?\z/
                     cols_value.to_i
                   else
                     :invalid  # Mark as invalid for validation
                   end
          end
          offset = has_offset ? @stack.pop : nil
          limit = has_limit ? @stack.pop : nil
          collection = @stack.pop
          iterator = create_tablerow_iterator(collection, loop_name, has_limit, limit, has_offset, offset, cols)
          @for_iterators.push(iterator)
          @pc += 1

        when IL::TABLEROW_NEXT
          label_continue = inst[1]
          label_break = inst[2]
          iterator = @for_iterators.last
          if iterator && iterator.has_next?
            # Skip all output if collection was nil/false
            unless iterator.skip_output
              # Close previous cell/row if not first iteration
              if iterator.index0 > 0
                write_output("</td>")
                if iterator.at_row_end?
                  write_output("</tr>\n")
                end
              end

              # Open new row if at start of row
              if iterator.at_row_start?
                write_output("<tr class=\"row#{iterator.row}\">\n") if iterator.row == 1
                write_output("<tr class=\"row#{iterator.row}\">") if iterator.row > 1
              end
              write_output("<td class=\"col#{iterator.col}\">")
            end

            value = iterator.next_value
            @stack.push(value)
            # NOTE: tablerow does NOT update forloop - it has its own tablerowloop variable
            # forloop.index0 should remain the enclosing for loop's index
            # Set up tablerowloop variable with col info
            tablerowloop = TablerowloopDrop.new(iterator.name, iterator.length, iterator.cols, nil, iterator.cols_explicit_nil)
            tablerowloop.index0 = iterator.index0 - 1
            @context.assign_local('tablerowloop', tablerowloop)
            @pc += 1
          else
            # Output empty row if no items (but only for real empty arrays, not nil/false)
            if iterator && iterator.index0 == 0 && !iterator.skip_output
              write_output("<tr class=\"row1\">\n")
            end
            @pc = label_break
          end

        when IL::TABLEROW_END
          iterator = @for_iterators.pop
          if iterator && !iterator.skip_output
            if iterator.index0 > 0
              # Close the last cell and row if we rendered items
              write_output("</td>")
              write_output("</tr>\n")
            elsif iterator.index0 == 0
              # Close empty row
              write_output("</tr>\n")
            end
          end
          @pc += 1

        when IL::STORE_TEMP
          # Use local register file for fast access (no method call)
          @regs[inst[1]] = @stack.pop
          @pc += 1

        when IL::LOAD_TEMP
          # Use local register file for fast access (no method call)
          @stack.push(@regs[inst[1]])
          @pc += 1

        when IL::IFCHANGED_CHECK
          tag_id = inst[1]
          captured = @stack.pop
          prev_value = @context.get_ifchanged_state(tag_id)
          if captured != prev_value
            @context.set_ifchanged_state(tag_id, captured)
            write_output(captured)
          end
          @pc += 1

        when IL::NOOP
          @pc += 1

        when IL::SET_CONTEXT
          @current_file = inst[1]
          @source = inst[2] if inst[2]
          @pc += 1

        else
          raise RuntimeError, "Unknown opcode: #{opcode}"
        end

        # Don't break immediately on interrupt - let JUMP_IF_INTERRUPT handle it
        # This allows capture blocks to complete before the interrupt propagates
      end

      @output
    rescue LiquidIL::RuntimeError => e
      # Attach partial output to the error so callers can use it
      e.partial_output = @output
      raise
    end

    private

    def write_output(str)
      return unless str
      # Skip output when there's a pending interrupt (break/continue)
      # This allows capture blocks to complete while suppressing further output
      return if @context.has_interrupt?
      if @context.capturing?
        @context.current_capture << str.to_s
      else
        @output << str.to_s
      end
    end

    # Read from file system, supporting both liquid-spec's read_template_file and our read interface
    def read_from_file_system(fs, name)
      return nil unless fs

      if fs.respond_to?(:read_template_file)
        begin
          fs.read_template_file(name)
        rescue StandardError
          nil
        end
      elsif fs.respond_to?(:read)
        fs.read(name)
      end
    end

    # --- Core abstractions ---

    # Convert any value to output string
    def to_output(value)
      Utils.output_string(value)
    end

    # Resolve cycle values - handles tagged [:lit, val] or [:var, name]
    def resolve_cycle_values(values)
      values.map do |v|
        if v.is_a?(Array) && v.length == 2
          type, val = v
          if type == :lit
            val
          elsif type == :var
            @context.lookup(val)
          else
            val
          end
        else
          v
        end
      end
    end

    # Convert to iterable for for loops
    def to_iterable(value)
      case value
      when nil
        []
      when true, false
        []
      when Integer, Float
        []
      when String
        value.empty? ? [] : [value]
      when RangeValue
        value.to_a
      when Array
        value
      when Hash
        value.map { |k, v| [k, v] }
      else
        # Try to_a first if available
        if value.respond_to?(:to_a)
          begin
            value.to_a
          rescue
            value.respond_to?(:each) ? value.to_enum.to_a : []
          end
        elsif value.respond_to?(:each)
          value.to_enum.to_a
        else
          []
        end
      end
    end

    # Check if value is truthy (Liquid semantics: only nil and false are falsy)
    def is_truthy(value)
      # Handle drops with to_liquid_value
      if value.respond_to?(:to_liquid_value)
        value = value.to_liquid_value
      end

      case value
      when nil, false
        false
      when EmptyLiteral, BlankLiteral
        false
      else
        true
      end
    end

    # Check if collection is empty
    def is_collection_empty(value)
      case value
      when nil
        true
      when Array
        value.empty?
      when Hash
        value.empty?
      when String
        value.empty?
      when RangeValue
        value.length <= 0
      else
        to_iterable(value).empty?
      end
    end

    # Check if value == empty
    def is_empty(value)
      case value
      when EmptyLiteral
        true
      when String
        value.empty?
      when Array
        value.empty?
      when Hash
        value.empty?
      else
        false
      end
    end

    # Check if value == blank
    def is_blank(value)
      case value
      when BlankLiteral
        true
      when nil
        true
      when false
        true
      when String
        value.empty? || value.strip.empty?
      when Array
        value.empty?
      when Hash
        value.empty?
      else
        false
      end
    end

    # Stricter blank check - only nil, false, empty string (NOT whitespace-only)
    # Used for "blank == value" comparisons where blank is the subject
    def is_blank_strict(value)
      case value
      when BlankLiteral
        true
      when nil
        true
      when false
        true
      when String
        value.empty?  # Only empty string, not whitespace-only
      when Array
        value.empty?
      when Hash
        value.empty?
      else
        false
      end
    end

    # Pure key lookup for bracket notation (no first/last commands for arrays)
    def lookup_key_only(obj, key)
      return nil if obj.nil?

      # Convert drop keys to their value
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)

      # Ranges cannot be used as hash keys - return nil directly
      return nil if key.is_a?(RangeValue) || key.is_a?(Range)

      case obj
      when Hash
        # Try the key directly first (handles integer keys)
        result = obj[key]
        return result unless result.nil?
        # Then try string key
        key_str = key.to_s
        result = obj[key_str]
        return result unless result.nil?
        result = obj[key.to_sym] if key.is_a?(String)
        # Bracket notation only does key lookup - no size/length methods
        result
      when Array
        # Only integer keys for bracket notation - no first/last commands
        if key.is_a?(Integer)
          obj[key]
        elsif key.to_s =~ /\A-?\d+\z/
          obj[key.to_i]
        else
          nil
        end
      when ForloopDrop, Drop
        obj[key]
      when String
        # Only integer keys for strings in bracket notation
        if key.is_a?(Integer)
          obj[key]
        elsif key.to_s =~ /\A-?\d+\z/
          obj[key.to_i]
        else
          nil
        end
      else
        # For any object with [] method
        obj[key] if obj.respond_to?(:[])
      end
    end

    # Property lookup (dot notation - includes first/last/size commands)
    def lookup_property(obj, key)
      return nil if obj.nil?

      # Convert drop keys to their value
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)

      case obj
      when Hash
        key_str = key.to_s
        # Try string key first, then symbol
        result = obj[key_str]
        return result unless result.nil?
        result = obj[key.to_sym] if key.is_a?(String)
        return result unless result.nil?
        # Check for special commands if key not found
        case key_str
        when "first"
          pair = obj.first
          pair ? "#{pair[0]}#{pair[1]}" : nil
        when "size", "length"
          obj.length
        else
          nil
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
        else
          nil
        end
      when ForloopDrop, Drop
        obj[key]
      when RangeValue
        key_str = key.to_s
        case key_str
        when "first"
          obj.first
        when "last"
          obj.last
        when "size", "length"
          obj.length
        else
          nil
        end
      when String
        key_str = key.to_s
        case key_str
        when "size", "length"
          obj.length
        when "first"
          obj[0]
        when "last"
          obj[-1]
        else
          nil
        end
      when Integer
        # Integers only respond to size (returns byte size)
        if key.to_s == "size"
          obj.size
        else
          nil
        end
      when Float
        # Floats don't respond to any properties
        nil
      else
        # Try method call first if key is a valid method name
        if key.is_a?(String) && obj.respond_to?(key.to_sym)
          obj.send(key.to_sym)
        elsif obj.respond_to?(:[])
          obj[key.to_s]
        else
          nil
        end
      end
    end

    # Execute command (size, first, last)
    def execute_command(obj, command)
      case command
      when "size", "length"
        case obj
        when Array, String, Hash
          obj.length
        when RangeValue
          obj.length
        else
          obj.respond_to?(:length) ? obj.length : nil
        end
      when "first"
        case obj
        when Array
          obj.first
        when RangeValue
          obj.start_val
        else
          nil
        end
      when "last"
        case obj
        when Array
          obj.last
        when RangeValue
          obj.end_val
        else
          nil
        end
      else
        nil
      end
    end

    # Compare values
    def compare(left, right, op)
      # Handle drops with to_liquid_value for comparisons
      left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
      right = right.to_liquid_value if right.respond_to?(:to_liquid_value)

      # Normalize Ruby Range to RangeValue for comparison
      left = RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
      right = RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

      # Handle empty/blank comparisons
      # For "value == blank/empty" comparisons, check if value is blank/empty
      # Note: blank == blank and empty == empty are always false
      if right.is_a?(EmptyLiteral)
        return false if left.is_a?(EmptyLiteral) || left.is_a?(BlankLiteral)
        return is_empty(left) if op == :eq
        return !is_empty(left) if op == :ne
      end
      if right.is_a?(BlankLiteral)
        return false if left.is_a?(EmptyLiteral) || left.is_a?(BlankLiteral)
        return is_blank(left) if op == :eq
        return !is_blank(left) if op == :ne
      end
      if left.is_a?(EmptyLiteral)
        return is_empty(right) if op == :eq
        return !is_empty(right) if op == :ne
      end
      if left.is_a?(BlankLiteral)
        return is_blank(right) if op == :eq
        return !is_blank(right) if op == :ne
      end

      case op
      when :eq
        left == right
      when :ne
        left != right
      when :lt
        compare_numeric(left, right) { |a, b| a < b }
      when :le
        compare_numeric(left, right) { |a, b| a <= b }
      when :gt
        compare_numeric(left, right) { |a, b| a > b }
      when :ge
        compare_numeric(left, right) { |a, b| a >= b }
      else
        false
      end
    end

    # Case/when comparison - asymmetric blank/empty handling
    # - Case value is blank/empty: only match nil/false/empty (strict)
    # - When value is blank/empty: check if case value is blank (inclusive)
    def case_compare(left, right)
      # Handle drops with to_liquid_value for comparisons
      left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
      right = right.to_liquid_value if right.respond_to?(:to_liquid_value)

      # Normalize Ruby Range to RangeValue for comparison
      left = RangeValue.new(left.begin, left.end) if left.is_a?(Range) && !left.exclude_end?
      right = RangeValue.new(right.begin, right.end) if right.is_a?(Range) && !right.exclude_end?

      # Case value (left) is blank/empty: use stricter matching
      # {% case blank %}{% when ' ' %} should NOT match
      if left.is_a?(BlankLiteral) || left.is_a?(EmptyLiteral)
        return is_blank_strict(right) if left.is_a?(BlankLiteral)
        return is_empty(right) if left.is_a?(EmptyLiteral)
      end

      # When value (right) is blank/empty: use inclusive matching
      # {% case ' ' %}{% when blank %} SHOULD match (space is blank)
      if right.is_a?(BlankLiteral) || right.is_a?(EmptyLiteral)
        return is_blank(left) if right.is_a?(BlankLiteral)
        return is_empty(left) if right.is_a?(EmptyLiteral)
      end

      # Regular comparison
      left == right
    end

    def compare_numeric(left, right)
      # nil, true, false, Array, Hash, Range comparisons are always silently false
      return false if left.nil? || right.nil?
      return false if left == true || left == false || right == true || right == false
      return false if left.is_a?(Array) || left.is_a?(Hash) || right.is_a?(Array) || right.is_a?(Hash)
      return false if left.is_a?(RangeValue) || right.is_a?(RangeValue)

      left_num = to_number(left)
      right_num = to_number(right)
      if left_num.nil? || right_num.nil?
        # Format: "comparison of LeftClass with right_value_or_class failed"
        # Show value for numbers, class for other types (like String)
        right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
        raise ArgumentError, "comparison of #{left.class} with #{right_str} failed"
      end
      yield(left_num, right_num)
    end

    def to_number(value)
      case value
      when Integer, Float
        value
      when String
        if value =~ /\A-?\d+\z/
          value.to_i
        elsif value =~ /\A-?\d+\.\d+\z/
          value.to_f
        else
          nil
        end
      else
        nil
      end
    end

    def to_integer(value)
      number = to_number(value)
      number ? number.to_i : 0
    end

    # Check if value is a valid integer (for error throwing)
    def valid_integer?(value)
      return true if value.nil?  # nil is treated as 0
      return true if value.is_a?(Integer)
      return true if value.is_a?(Float)  # floats are truncated
      # Strings starting with optional minus and digit are valid (to_i extracts leading number)
      # "0x10" → valid (to_i = 0), "limit" → invalid (doesn't start with digit)
      return true if value.is_a?(String) && value =~ /\A-?\d/
      false
    end

    # Contains check
    def contains(left, right)
      # contains cannot find nil values
      return false if right.nil?

      case left
      when String
        right_str = right.to_s
        # Handle encoding mismatches gracefully
        if left.encoding != right_str.encoding
          # Try to convert both to UTF-8
          begin
            left = left.dup.force_encoding(Encoding::UTF_8)
            right_str = right_str.dup.force_encoding(Encoding::UTF_8)
          rescue
            return false
          end
        end
        left.include?(right_str) rescue false
      when Array
        left.include?(right)
      when Hash
        left.key?(right.to_s) || (right.is_a?(String) && left.key?(right.to_sym))
      else
        false
      end
    end

    # Create iterator for for loop
    def create_iterator(collection, loop_name, has_limit, limit, has_offset, offset, offset_continue, reversed)
      # Track if collection was nil/false - these skip validation
      is_nil_collection = collection.nil? || collection == false
      # Track if collection is a string - strings ignore offset/limit
      is_string_collection = collection.is_a?(String)
      items = to_iterable(collection)

      # Validate limit/offset only if collection is defined (not nil/false)
      unless is_nil_collection
        if has_limit && !valid_integer?(limit)
          raise_error "invalid integer"
        end
        if has_offset && !valid_integer?(offset)
          raise_error "invalid integer"
        end
      end

      # Calculate 'from' (offset)
      from = 0
      if offset_continue
        from = @context.for_offset(loop_name)
      elsif !offset.nil?
        from = to_integer(offset)
      end

      # Calculate 'to' (from + limit) - this is how Liquid handles it
      # With negative offset, to is also reduced, resulting in fewer items
      to = nil
      if !limit.nil?
        limit_val = to_integer(limit)
        to = from + limit_val
      end

      # Slice collection using Liquid's algorithm
      # Strings ignore offset and limit
      items = slice_collection(items, from, to, is_string: is_string_collection)

      items = items.reverse if reversed
      # Store the clamped offset for forloop tracking (must be >= 0)
      actual_offset = [from, 0].max
      ForIterator.new(items, loop_name, start_offset: actual_offset, offset_continue: offset_continue)
    end

    # Slice collection like Liquid does: collect items where from <= index < to
    # Strings are special: always return [string] regardless of from/to
    def slice_collection(collection, from, to, is_string: false)
      # Strings ignore offset and limit, always iterate once
      return collection if is_string

      segments = []
      index = 0

      collection.each do |item|
        break if to && to <= index

        if from <= index
          segments << item
        end

        index += 1
      end

      segments
    end

    # Create iterator for tablerow
    def create_tablerow_iterator(collection, loop_name, has_limit, limit, has_offset, offset, cols)
      # Track if collection was nil/false - these should produce no output at all
      is_nil_collection = collection.nil? || collection == false

      items = to_iterable(collection)

      # For strings, limit and offset are ignored (string is always treated as single item)
      is_string_collection = collection.is_a?(String)

      # Validate limit/offset/cols only if collection is defined (not nil/false)
      # "Tablerow doesn't throw error when limit isn't a number and lookup is undefined"
      unless is_nil_collection
        if has_limit && !valid_integer?(limit)
          raise_error "invalid integer"
        end
        if has_offset && !valid_integer?(offset)
          raise_error "invalid integer"
        end
        # Validate cols (check for :invalid marker or non-integer value)
        if cols == :invalid || (cols && !cols.is_a?(Symbol) && !valid_integer?(cols))
          raise_error "invalid integer"
        end
      end

      if has_offset && !is_string_collection
        start_offset = offset.nil? ? 0 : to_integer(offset)
        start_offset = [start_offset, 0].max
        items = items.drop(start_offset) if start_offset > 0
      end

      # For tablerow, nil limit means 0 items (but not for strings)
      if has_limit && !is_string_collection
        limit_val = limit.nil? ? 0 : to_integer(limit)
        limit_val = 0 if limit_val < 0
        items = items.take(limit_val)
      end

      # Handle explicit nil cols (cols:nil in template)
      cols_explicit_nil = (cols == :explicit_nil)
      actual_cols = cols_explicit_nil ? nil : cols

      TablerowIterator.new(items, loop_name, cols: actual_cols, skip_output: is_nil_collection, cols_explicit_nil: cols_explicit_nil)
    end

    # Evaluate a simple expression like "foo", "foo.bar", "foo[0]", or "'literal'"
    def eval_expression(expr)
      return nil unless expr
      expr_str = expr.to_s

      # Handle string literals (quoted strings)
      if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
        return Regexp.last_match(1)
      end

      # Handle range literals (1..10)
      if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
        return RangeValue.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
      end

      parts = expr_str.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
      return nil if parts.empty?

      result = nil
      parts.each_with_index do |match, idx|
        if idx == 0
          # First part is always a variable name
          result = @context.lookup(match[0])
        else
          # Subsequent parts are property access
          key = match[0] || match[1] || match[2]
          result = lookup_property(result, key.to_s =~ /^\d+$/ ? key.to_i : key)
        end
      end
      result
    end

    # Render partial
    def render_partial(name, args, isolated:)
      # Check for invalid template name (nil, number, etc.)
      if args["__invalid_name__"]
        tag_type = isolated ? "render" : "include"
        raise_error "Argument error in tag '#{tag_type}' - Illegal template name"
      end

      compiled_template = args["__compiled_template__"]

      unless compiled_template
        return unless @context.file_system

        # Handle dynamic template name
        if args["__dynamic_name__"]
          resolved_name = eval_expression(args["__dynamic_name__"])
          # Validate template name - must be a non-nil string
          if resolved_name.nil? || !resolved_name.is_a?(String)
            tag_type = isolated ? "render" : "include"
            raise_error "Argument error in tag '#{tag_type}' - Illegal template name"
          end
          name = resolved_name
        end

        source = read_from_file_system(@context.file_system, name)
        unless source
          raise_error "Could not find asset #{name}"
        end
      else
        source = compiled_template[:source]
      end

      # Handle with/for
      with_expr = args["__with__"]
      for_expr = args["__for__"]
      as_alias = args["__as__"]

      if for_expr
        # Render once per item in the collection
        collection = eval_expression(for_expr)
        # For include/render "for": Arrays, ranges, and enumerable drops iterate,
        # but hashes, strings, and simple values render once as a single item
        if collection.is_a?(Array)
          # Empty array = don't render at all
          collection.each_with_index do |item, idx|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated,
                               forloop_index: idx, forloop_length: collection.length, has_item: true,
                               compiled_template: compiled_template)
          end
        elsif (collection.is_a?(RangeValue) || collection.is_a?(Range)) && isolated
          # Ranges iterate over their values ONLY for render (isolated)
          # For include (non-isolated), ranges render as a single item
          items = collection.to_a
          items.each_with_index do |item, idx|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated,
                               forloop_index: idx, forloop_length: items.length, has_item: true,
                               compiled_template: compiled_template)
          end
        elsif !collection.is_a?(Hash) && !collection.is_a?(String) && !collection.is_a?(Range) && !collection.is_a?(RangeValue) && collection.respond_to?(:each) && collection.respond_to?(:to_a)
          # Enumerable drop - iterate over it (but not strings, hashes, or ranges for include)
          items = collection.to_a
          items.each_with_index do |item, idx|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated,
                               forloop_index: idx, forloop_length: items.length, has_item: true,
                               compiled_template: compiled_template)
          end
        elsif collection.nil?
          # Nil collection = render once with keyword args only (no item from for loop)
          render_partial_once(name, source, args, nil, as_alias, isolated: isolated, has_item: false,
                               compiled_template: compiled_template)
        else
          # Single item (including hashes and strings) - render once with it
          render_partial_once(name, source, args, collection, as_alias, isolated: isolated, has_item: true,
                               compiled_template: compiled_template)
        end
      elsif with_expr
        # Render with the variable
        item = eval_expression(with_expr)
        # For include (non-isolated) with arrays: iterate over array items
        # For render (isolated) with arrays: render once with array as single item
        if item.is_a?(Array) && !isolated
          # Include with array - iterate like "for"
          item.each do |array_item|
            render_partial_once(name, source, args, array_item, as_alias, isolated: isolated, has_item: true,
                               compiled_template: compiled_template)
          end
        else
          # For render (isolated), nil/undefined with expr lets keyword arg take precedence
          # For include (non-isolated), nil with expr still overrides keyword arg
          has_item = isolated ? !item.nil? : true
          render_partial_once(name, source, args, item, as_alias, isolated: isolated, has_item: has_item,
                               compiled_template: compiled_template)
        end
      else
        render_partial_once(name, source, args, nil, nil, isolated: isolated, has_item: false,
                             compiled_template: compiled_template)
      end
    end

    def render_partial_once(name, source, args, item, as_alias, isolated:, forloop_index: nil, forloop_length: nil, has_item: false, compiled_template: nil)
      # Track render depth to prevent infinite recursion
      @context.push_render_depth
      # include uses stricter limit (>= 100), render allows one more level (> 100)
      if @context.render_depth_exceeded?(strict: !isolated)
        raise LiquidIL::RuntimeError.new("Nesting too deep", file: name, line: current_line)
      end

      if isolated
        partial_context = @context.isolated
      else
        # For include: use same context, assignments persist
        partial_context = @context
      end

      # Apply arguments
      args.each do |k, v|
        next if k.start_with?("__")
        # Handle variable lookups
        if v.is_a?(Hash) && v[:__var__]
          v = eval_expression(v[:__var__])
        end
        partial_context.assign(k, v)
      end

      # Assign the item to the alias or partial name variable
      # When has_item is true, we always assign (even if item is nil/false)
      # This ensures "with" clause values override keyword args with the same name
      if has_item
        var_name = as_alias || name
        partial_context.assign(var_name, item)
      end

      # Set up forloop variable if we're iterating (render only, not include)
      # IMPORTANT: include with 'for' does NOT provide a forloop object
      if forloop_index && isolated
        forloop = ForloopDrop.new('forloop', forloop_length)
        forloop.index0 = forloop_index
        partial_context.assign('forloop', forloop)
      end

      template = if compiled_template
                   compiled_template[:template] ||= Template.new(
                     compiled_template[:source],
                     compiled_template[:instructions],
                     compiled_template[:spans]
                   )
                 else
                   Template.parse(source)
                 end

      result = VM.execute(template.instructions, partial_context,
                          current_file: name, spans: template.spans, source: source)
      write_output(result)
    rescue LiquidIL::SyntaxError => e
      raise unless @context.render_errors
      line = if e.respond_to?(:line) && e.position
               e.line
             elsif e.message =~ /at position (\d+)/
               pos = $1.to_i
               source[0, pos].count("\n") + 1
             else
               1
             end
      write_output("Liquid syntax error (#{name} line #{line}): #{e.message}")
    rescue LiquidIL::RuntimeError => e
      raise unless @context.render_errors
      write_output(e.partial_output) if e.partial_output
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      write_output("Liquid error (#{location}): #{e.message}")
    rescue StandardError => e
      raise unless @context.render_errors
      write_output("Liquid error (#{name} line 1): #{LiquidIL.clean_error_message(e.message)}")
    ensure
      @context.pop_render_depth
    end
  end

  # Iterator for for loops
  class ForIterator
    attr_reader :name, :length, :index0, :start_offset

    def initialize(items, name, start_offset: 0, offset_continue: false)
      @items = items
      @name = name
      @length = items.length
      @index0 = 0
      @start_offset = start_offset
      @offset_continue = offset_continue
    end

    def offset_continue?
      @offset_continue
    end

    def next_offset
      @start_offset + @index0
    end

    def has_next?
      @index0 < @length
    end

    def next_value
      value = @items[@index0]
      @index0 += 1
      value
    end

    def current_index
      @index0 - 1
    end
  end

  # Iterator for tablerow loops
  class TablerowIterator
    attr_reader :name, :length, :index0, :cols, :skip_output, :cols_explicit_nil

    def initialize(items, name, cols: nil, skip_output: false, cols_explicit_nil: false)
      @items = items
      @name = name
      @length = items.length
      @index0 = 0
      @cols_explicit_nil = cols_explicit_nil  # true when cols:nil was explicitly written
      @cols = cols || @length  # default: all items in one row
      @skip_output = skip_output  # true for nil/false collections - no row tags output
    end

    def has_next?
      @index0 < @length
    end

    def next_value
      value = @items[@index0]
      @index0 += 1
      value
    end

    # Current row number (1-based)
    def row
      ((@index0) / @cols) + 1
    end

    # Current column number (1-based)
    def col
      ((@index0) % @cols) + 1
    end

    # Are we at the start of a row?
    def at_row_start?
      (@index0 % @cols) == 0
    end

    # Are we at the end of a row (just finished the last column)?
    def at_row_end?
      (@index0 % @cols) == 0
    end
  end
end
