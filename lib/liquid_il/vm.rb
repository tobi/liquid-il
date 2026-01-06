# frozen_string_literal: true

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
          @stack.push(lookup_property(obj, key))
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
            @pc = inst[1]
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
          collection = @stack.pop
          iterator = create_iterator(collection, loop_name)
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
          @for_iterators.pop
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
          result = @context.cycle_step(identity, values)
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
      # Handle to_liquid first
      value = value.to_liquid if value.respond_to?(:to_liquid)

      case value
      when nil
        ""
      when true
        "true"
      when false
        "false"
      when Integer, Float
        value.to_s
      when String
        value
      when RangeValue
        value.to_s
      when Array
        value.map { |v| to_output(v) }.join
      when Hash
        value.to_s
      when EmptyLiteral, BlankLiteral
        ""
      else
        value.to_s
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
        if value.respond_to?(:each)
          value.to_a
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

    # Property lookup
    def lookup_property(obj, key)
      return nil if obj.nil?

      # Convert drop keys to their value
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)

      case obj
      when Hash
        key_str = key.to_s
        # Try string key first, then symbol (for strings only)
        result = obj[key_str]
        return result unless result.nil?
        result = obj[key.to_sym] if key.is_a?(String)
        return result unless result.nil?
        # Check for special commands if key not found
        case key_str
        when "first"
          pair = obj.first
          pair ? "#{pair[0]}#{pair[1]}" : nil
        when "last"
          pair = obj.to_a.last
          pair ? "#{pair[0]}#{pair[1]}" : nil
        when "size", "length"
          obj.length
        else
          obj[key]
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
      when Liquid::Drop
        # Liquid gem drops use [] for property access
        obj[key.to_s]
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
      if right.is_a?(EmptyLiteral)
        return is_empty(left) if op == :eq
        return !is_empty(left) if op == :ne
      end
      if right.is_a?(BlankLiteral)
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
    def create_iterator(collection, loop_name)
      items = to_iterable(collection)
      ForIterator.new(items, loop_name)
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
        # Render once per item in the collection (only arrays iterate, others are single item)
        collection = eval_expression(for_expr)
        if collection.is_a?(Array)
          collection.each do |item|
            render_partial_once(name, source, args, item, as_alias, isolated: isolated)
          end
        else
          # Single item - render once
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

    def render_partial_once(name, source, args, item, as_alias, isolated:)
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

      template = Template.parse(source)
      result = VM.execute(template.instructions, partial_context)
      write_output(result)
    end
  end

  # Iterator for for loops
  class ForIterator
    attr_reader :name, :length, :index0

    def initialize(items, name)
      @items = items
      @name = name
      @length = items.length
      @index0 = 0
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
end
