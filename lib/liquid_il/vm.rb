# frozen_string_literal: true

require_relative "utils"

module LiquidIL
  # Virtual Machine - executes IL instructions
  class VM
    class << self
      def execute(instructions, context)
        vm = new(instructions, context)
        vm.run
      end
    end

    def initialize(instructions, context)
      @instructions = instructions
      @context = context
      @stack = []
      @output = String.new
      @pc = 0  # Program counter
      @for_iterators = []  # Stack of iterators for FOR_NEXT
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
          write_output(to_output(value))
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
          @stack.push(compare(left, right, op))
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
          @context.assign(name, value)
          @pc += 1

        when IL::NEW_RANGE
          end_val = @stack.pop
          start_val = @stack.pop
          @stack.push(RangeValue.new(start_val, end_val))
          @pc += 1

        when IL::CALL_FILTER
          name = inst[1]
          argc = inst[2]
          args = @stack.pop(argc)
          input = @stack.pop
          result = Filters.apply(name, input, args, @context)
          @stack.push(result)
          @pc += 1

        when IL::FOR_INIT
          var_name = inst[1]
          loop_name = inst[2]
          has_limit = inst[3]
          has_offset = inst[4]
          offset_continue = inst[5]
          reversed = inst[6]
          offset = has_offset ? @stack.pop : nil
          limit = has_limit ? @stack.pop : nil
          collection = @stack.pop
          iterator = create_iterator(collection, loop_name, limit, offset, offset_continue, reversed)
          @for_iterators.push(iterator)
          @pc += 1

        when IL::FOR_NEXT
          label_continue = inst[1]
          label_break = inst[2]
          iterator = @for_iterators.last
          if iterator && iterator.has_next?
            value = iterator.next_value
            @stack.push(value)
            # Update forloop if present
            forloop = @context.current_forloop
            forloop.index0 = iterator.index0 - 1 if forloop
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
          @context.assign("forloop", forloop)
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
          render_partial(name, args, isolated: false)
          @pc += 1

        when IL::DUP
          @stack.push(@stack.last)
          @pc += 1

        when IL::POP
          @stack.pop
          @pc += 1

        when IL::TABLEROW_INIT
          var_name = inst[1]
          loop_name = inst[2]
          has_limit = inst[3]
          has_offset = inst[4]
          cols = inst[5]
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

            value = iterator.next_value
            @stack.push(value)
            # Update forloop
            forloop = @context.current_forloop
            forloop.index0 = iterator.index0 - 1 if forloop
            @pc += 1
          else
            # Output empty row if no items
            if iterator && iterator.index0 == 0
              write_output("<tr class=\"row1\">\n")
            end
            @pc = label_break
          end

        when IL::TABLEROW_END
          iterator = @for_iterators.pop
          if iterator
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
          index = inst[1]
          value = @stack.pop
          @context.store_temp(index, value)
          @pc += 1

        when IL::LOAD_TEMP
          index = inst[1]
          value = @context.load_temp(index)
          @stack.push(value)
          @pc += 1

        when IL::NOOP
          @pc += 1

        else
          raise RuntimeError, "Unknown opcode: #{opcode}"
        end

        # Check for interrupts after each instruction if in block body
        break if @context.has_interrupt? && should_propagate_interrupt?
      end

      @output
    end

    private

    def write_output(str)
      return unless str
      if @context.capturing?
        @context.current_capture << str.to_s
      else
        @output << str.to_s
      end
    end

    def should_propagate_interrupt?
      # In a simple VM, we always propagate
      # More sophisticated implementations might track block nesting
      true
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

    # Pure key lookup for bracket notation (no first/last commands for arrays)
    def lookup_key_only(obj, key)
      return nil if obj.nil?

      # Convert drop keys to their value
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)

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
        return result unless result.nil?
        # For hashes, size/length are accessible via bracket notation
        case key_str
        when "size", "length"
          obj.length
        else
          nil
        end
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
        if key.to_s == "size" || key.to_s == "length"
          obj.length
        else
          nil
        end
      else
        if obj.respond_to?(:[])
          obj[key.to_s] rescue nil
        elsif key.is_a?(String) && obj.respond_to?(key.to_sym)
          obj.send(key.to_sym) rescue nil
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

    def compare_numeric(left, right)
      left_num = to_number(left)
      right_num = to_number(right)
      return false if left_num.nil? || right_num.nil?
      yield(left_num, right_num)
    rescue
      false
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

    # Contains check
    def contains(left, right)
      case left
      when String
        left.include?(right.to_s)
      when Array
        left.include?(right)
      when Hash
        left.key?(right.to_s) || (right.is_a?(String) && left.key?(right.to_sym))
      else
        false
      end
    end

    # Create iterator for for loop
    def create_iterator(collection, loop_name, limit, offset, offset_continue, reversed)
      items = to_iterable(collection)

      start_offset = 0
      if offset_continue
        start_offset = @context.for_offset(loop_name)
      elsif !offset.nil?
        start_offset = to_integer(offset)
      end

      start_offset = [start_offset, 0].max
      items = items.drop(start_offset) if start_offset > 0

      if !limit.nil?
        limit = to_integer(limit)
        limit = 0 if limit < 0
        items = items.take(limit)
      end

      items = items.reverse if reversed
      ForIterator.new(items, loop_name, start_offset: start_offset, offset_continue: offset_continue)
    end

    # Create iterator for tablerow
    def create_tablerow_iterator(collection, loop_name, has_limit, limit, has_offset, offset, cols)
      items = to_iterable(collection)

      # For strings, limit and offset are ignored (string is always treated as single item)
      is_string_collection = collection.is_a?(String)

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

      TablerowIterator.new(items, loop_name, cols: cols)
    end

    # Evaluate a simple expression like "foo", "foo.bar", or "foo[0]"
    def eval_expression(expr)
      return nil unless expr
      parts = expr.to_s.scan(/(\w+)|\[(\d+)\]|\[['"](\w+)['"]\]/)
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
      return unless @context.file_system

      # Handle dynamic template name
      if args["__dynamic_name__"]
        name = eval_expression(args["__dynamic_name__"]).to_s
      end

      source = @context.file_system.read(name)
      return unless source

      # Handle with/for
      with_expr = args["__with__"]
      for_expr = args["__for__"]
      as_alias = args["__as__"]

      if for_expr
        # Render once per item in the collection
        collection = eval_expression(for_expr)
        # For include/render "for": Arrays and enumerable drops iterate,
        # but hashes and simple values render once as a single item
        if collection.is_a?(Array)
          collection.each_with_index do |item, idx|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated,
                               forloop_index: idx, forloop_length: collection.length)
          end
        elsif !collection.is_a?(Hash) && collection.respond_to?(:each) && collection.respond_to?(:to_a)
          # Enumerable drop - iterate over it
          items = collection.to_a
          items.each_with_index do |item, idx|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated,
                               forloop_index: idx, forloop_length: items.length)
          end
        else
          # Single item (including hashes) - render once with it
          render_partial_once(name, source, args, collection, as_alias, isolated: isolated)
        end
      elsif with_expr
        # Render once with the variable
        item = eval_expression(with_expr)
        render_partial_once(name, source, args, item, as_alias, isolated: isolated)
      else
        render_partial_once(name, source, args, nil, nil, isolated: isolated)
      end
    end

    def render_partial_once(name, source, args, item, as_alias, isolated:, forloop_index: nil, forloop_length: nil)
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
      if item
        var_name = as_alias || name
        partial_context.assign(var_name, item)
      end

      # Set up forloop variable if we're iterating
      if forloop_index
        forloop = ForloopDrop.new('forloop', forloop_length)
        forloop.index0 = forloop_index
        partial_context.assign('forloop', forloop)
      end

      template = Template.parse(source)
      result = VM.execute(template.instructions, partial_context)
      write_output(result)
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
    attr_reader :name, :length, :index0, :cols

    def initialize(items, name, cols: nil)
      @items = items
      @name = name
      @length = items.length
      @index0 = 0
      @cols = cols || @length  # default: all items in one row
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
