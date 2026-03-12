# frozen_string_literal: true

# Shared helper lambdas for StructuredCompiler-generated code.
# Created once at module load time, referenced by all compiled templates.
# This avoids re-parsing ~250 lines of Ruby on every template eval().

module LiquidIL
  module StructuredHelpers
    @initialized = false

    # Hash keys with special semantics (size→length, first→pair)
    SPECIAL_KEYS = { "size" => true, "length" => true, "first" => true, "last" => true }.freeze

    def self.init
      return if @initialized
      @initialized = true
    end

    # Property lookup — replaces inline_lookup generated code.
    # Hot path: Hash string key (most common in Liquid templates).
    def self.lookup_prop(obj, key)
      if obj.is_a?(Hash)
        if SPECIAL_KEYS[key]
          LOOKUP.call(obj, key)
        else
          obj.fetch(key) { obj[key.to_sym] }
        end
      else
        LOOKUP.call(obj, key)
      end
    end

    # Inline output append — replaces 7-line case statement in generated code with 1 method call.
    # Hot path: String is most common, then Integer/Float.
    def self.output_append(output, value)
      case value
      when String then output << value
      when Integer, Float then output << value.to_s
      when nil then nil
      when true then output << "true"
      when false then output << "false"
      when LiquidIL::ErrorMarker then output << value.to_s
      else output << LiquidIL::Utils.output_string(value)
      end
    end

    OUTPUT_STRING = ->(value) {
      case value
      when Integer, Float then value.to_s
      when nil then ""
      when true then "true"
      when false then "false"
      when Array then value.map { |i| i.is_a?(String) ? i : OUTPUT_STRING.call(i) }.join
      else LiquidIL::Utils.output_string(value)
      end
    }

    IS_TRUTHY = ->(value) {
      value = value.to_liquid_value if value.respond_to?(:to_liquid_value)
      case value
      when nil, false then false
      when LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral then false
      else true
      end
    }

    LOOKUP = ->(obj, key) {
      return nil if obj.nil?
      case obj
      when Hash
        key_s = key.to_s
        obj[key_s] || obj[key_s.to_sym] || case key_s
          when "first" then (p = obj.first) ? "#{p[0]}#{p[1]}" : nil
          when "size", "length" then obj.length
          end
      when Array
        case key
        when Integer then obj[key]
        else
          case key.to_s
          when "size", "length" then obj.length
          when "first" then obj.first
          when "last" then obj.last
          else obj[key.to_i]
          end
        end
      when LiquidIL::ForloopDrop, LiquidIL::Drop then obj[key]
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
        case key.to_s
        when "size" then obj.size
        end
      else
        obj.respond_to?(:[]) ? obj[key.to_s] : nil
      end
    }

    CALL_FILTER = ->(name, input, args, scope, current_file = nil, line = 1) do
      LiquidIL::Filters.apply(name, input, args, scope)
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      LiquidIL::ErrorMarker.new(e.message, location)
    end

    COMPARE = ->(left, right, op, output = nil, current_file = nil) {
      left = left.to_liquid_value if left.respond_to?(:to_liquid_value)
      right = right.to_liquid_value if right.respond_to?(:to_liquid_value)

      if left.is_a?(Range) && right.is_a?(LiquidIL::RangeValue)
        left = LiquidIL::RangeValue.new(left.begin, left.end)
      elsif left.is_a?(LiquidIL::RangeValue) && right.is_a?(Range)
        right = LiquidIL::RangeValue.new(right.begin, right.end)
      end

      # empty/blank literals never equal each other
      if (left.is_a?(LiquidIL::EmptyLiteral) || left.is_a?(LiquidIL::BlankLiteral)) &&
         (right.is_a?(LiquidIL::EmptyLiteral) || right.is_a?(LiquidIL::BlankLiteral))
        return op == :ne if [:eq, :ne].include?(op)
        return false
      end

      if right.is_a?(LiquidIL::EmptyLiteral)
        is_empty = !left.nil? && (left == "" || left == [] || (left.respond_to?(:empty?) && left.empty?))
        return op == :eq ? is_empty : !is_empty if [:eq, :ne].include?(op)
      end
      if right.is_a?(LiquidIL::BlankLiteral)
        is_blank = left.nil? || left == false ||
                   (left.is_a?(String) && left.strip.empty?) ||
                   (left.respond_to?(:empty?) && left.empty?)
        return op == :eq ? is_blank : !is_blank if [:eq, :ne].include?(op)
      end
      if left.is_a?(LiquidIL::EmptyLiteral)
        is_empty = !right.nil? && (right == "" || right == [] || (right.respond_to?(:empty?) && right.empty?))
        return op == :eq ? is_empty : !is_empty if [:eq, :ne].include?(op)
      end
      if left.is_a?(LiquidIL::BlankLiteral)
        is_blank = right.nil? || right == false ||
                   (right.is_a?(String) && right.strip.empty?) ||
                   (right.respond_to?(:empty?) && right.empty?)
        return op == :eq ? is_blank : !is_blank if [:eq, :ne].include?(op)
      end

      if [:lt, :le, :gt, :ge].include?(op) && (left.nil? || right.nil?)
        return false
      end

      case op
      when :eq then left == right
      when :ne then left != right
      when :lt, :le, :gt, :ge
        return false if left == true || left == false || right == true || right == false
        return false if left.is_a?(Array) || left.is_a?(Hash) || right.is_a?(Array) || right.is_a?(Hash)
        return false if left.is_a?(LiquidIL::RangeValue) || right.is_a?(LiquidIL::RangeValue)

        left_num = TO_NUM.call(left)
        right_num = TO_NUM.call(right)

        if left_num.nil? || right_num.nil?
          if output
            right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
            location = current_file ? "#{current_file} line 1" : "line 1"
            output << "Liquid error (#{location}): comparison of #{left.class} with #{right_str} failed"
          end
          return false
        end

        case op
        when :lt then left_num < right_num
        when :le then left_num <= right_num
        when :gt then left_num > right_num
        when :ge then left_num >= right_num
        end
      else false
      end
    }

    TO_NUM = ->(v) {
      case v
      when Integer, Float then v
      when String
        if v =~ /\A-?\d+\z/ then v.to_i
        elsif v =~ /\A-?\d+\.\d+\z/ then v.to_f
        else nil
        end
      else nil
      end
    }

    CONTAINS = ->(left, right) {
      return false if left.nil? || right.nil?
      case left
      when String then left.include?(right.to_s)
      when Array then left.include?(right)
      when Hash then left.key?(right.to_s) || left.key?(right.to_s.to_sym)
      else false
      end
    }

    TO_ITERABLE = ->(value) {
      case value
      when nil, true, false, Integer, Float
        []
      when String
        value.empty? ? [] : [value]
      when LiquidIL::RangeValue
        value.to_a
      when Array
        value
      when Hash
        value.map { |k, v| [k, v] }
      else
        if value.respond_to?(:to_a)
          begin
            value.to_a
          rescue
            [value]
          end
        elsif value.respond_to?(:each)
          result = []
          value.each { |item| result << item }
          result
        else
          [value]
        end
      end
    }

    SLICE_COLLECTION = ->(collection, from, to) {
      if collection.is_a?(Array)
        from = 0 if from < 0
        sz = collection.length
        from = sz if from > sz
        if to
          to = 0 if to < 0
          to = sz if to > sz
          len = to - from
          len > 0 ? collection[from, len] : []
        elsif from > 0
          collection[from..] || []
        else
          collection
        end
      else
        segments = []
        index = 0
        collection.each do |item|
          break if to && to <= index
          segments << item if from <= index
          index += 1
        end
        segments
      end
    }

    VALID_INTEGER = ->(value) {
      return true if value.nil?
      return true if value.is_a?(Integer)
      return true if value.is_a?(Float)
      return true if value.is_a?(String) && value.match?(/\A-?\d/)
      false
    }

    BRACKET_LOOKUP = ->(obj, key) {
      return nil if obj.nil?
      return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)
      case obj
      when Hash
        result = obj[key]
        return result unless result.nil?
        key_str = key.to_s
        result = obj[key_str]
        return result unless result.nil?
        obj[key.to_sym] if key.is_a?(String)
      when Array
        if key.is_a?(Integer)
          obj[key]
        elsif key.to_s =~ /\A-?\d+\z/
          obj[key.to_i]
        else
          nil
        end
      when LiquidIL::ForloopDrop, LiquidIL::Drop
        obj[key]
      else
        nil
      end
    }

    # Runtime dynamic partial execution — used when partial name is a variable.
    # Compiles and runs the partial on-the-fly.
    def self.execute_dynamic_partial(name, assigns, output, scope, isolated:, tag_type: "include", caller_line: 1, parent_cycle_state: nil)
      # Validate the name
      unless name.is_a?(String) && !name.empty?
        location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
        output << "Liquid error (#{location}): Argument error in tag '#{tag_type}' - Illegal template name"
        return
      end

      fs = scope.file_system
      unless fs
        location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
        output << "Liquid error (#{location}): Could not find partial '#{name}'"
        return
      end

      # Load source
      source = fs.respond_to?(:read_template_file) ? (fs.read_template_file(name) rescue nil) : fs.read(name)
      unless source
        location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
        output << "Liquid error (#{location}): Could not find partial '#{name}'"
        return
      end

      # Compile and execute
      prev_file = scope.current_file
      scope.current_file = name
      scope.push_render_depth
      if scope.render_depth_exceeded?(strict: isolated)
        scope.current_file = prev_file
        scope.pop_render_depth
        raise LiquidIL::RuntimeError.new("Nesting too deep", file: name, line: 1, partial_output: output.dup)
      end

      begin
        dyn_ctx = LiquidIL::Context.new(file_system: fs)
        compiled = dyn_ctx.parse(source)
        child_scope = isolated ? scope.isolated : scope
        assigns.each { |k, v| child_scope.assign(k, v) }
        child_scope.file_system = fs
        child_scope.render_errors = scope.render_errors
        # Execute the compiled proc directly with the child scope
        result = compiled.instance_variable_get(:@compiled_proc).call(child_scope, compiled.spans, compiled.source)
        output << result
      rescue LiquidIL::RuntimeError => e
        raise unless scope.render_errors
        output << (e.partial_output || "")
        location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
        output << "Liquid error (#{location}): #{e.message}"
      rescue LiquidIL::SyntaxError => e
        raise unless scope.render_errors
        output << "Liquid syntax error (#{name} line #{e.line}): #{e.message}"
      rescue => e
        raise unless scope.render_errors
        output << "Liquid error (#{name} line 1): #{LiquidIL.clean_error_message(e.message)}"
      ensure
        scope.current_file = prev_file
        scope.pop_render_depth
      end
    end
  end
end
