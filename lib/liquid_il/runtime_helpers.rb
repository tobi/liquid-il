# frozen_string_literal: true

# Shared helper lambdas for RubyCompiler-generated code.
# Created once at module load time, referenced by all compiled templates.
# This avoids re-parsing ~250 lines of Ruby on every template eval().

module LiquidIL
  module RuntimeHelpers
    @initialized = false

    # Hash keys with special semantics (size→length, first→pair)
    SPECIAL_KEYS = { "size" => true, "length" => true, "first" => true, "last" => true }.freeze

    def self.init
      return if @initialized
      @initialized = true
    end

    # Property lookup — replaces inline_lookup generated code.
    # Hot path: Hash string key (most common in Liquid templates).
    def self.lookup_prop(obj, key, scope)
      # Fast path: avoid to_liquid call for Hash (most common case)
      if obj.is_a?(Hash)
        if SPECIAL_KEYS[key]
          lookup(obj, key, scope)
        else
          obj.fetch(key) { obj[key.to_sym] }
        end
      else
        lookup(obj, key, scope)
      end
    end

    # Fast path for hash property access with non-special keys
    # Skips SPECIAL_KEYS check — caller guarantees key isn't size/length/first/last
    def self.lookup_prop_fast(obj, key, scope)
      if obj.is_a?(Hash)
        # Avoid fetch block allocation: try string key first, sym fallback only if absent
        v = obj[key]
        v.nil? && !obj.key?(key) ? obj[key.to_sym] : v
      else
        lookup(obj, key, scope)
      end
    end

    # Pre-built frozen string table for small integers (0-999) — avoids Integer#to_s allocation
    INT_TO_S = Array.new(1000) { |i| i.to_s.freeze }.freeze

    # Inline output append — replaces 7-line case statement in generated code with 1 method call.
    # Hot path: String is most common, then Integer/Float.
    def self.output_append(output, value)
      case value
      when String then output << value
      when Integer
        # Fast path: use pre-built string for small non-negative integers (loop indices, counts)
        if value >= 0 && value < 1000
          output << INT_TO_S[value]
        else
          output << value.to_s
        end
      when Float then output << value.to_s
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

    def self.lookup(obj, key, scope)
      return nil if obj.nil?

      # Call to_liquid to unwrap drops/proxies before property access
      obj = obj.to_liquid if obj.respond_to?(:to_liquid)

      # Set the Liquid::Context on drops so they can access registers, locale, shop, etc.
      obj.context = scope if obj.respond_to?(:context=)

      result = case obj
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
      when LiquidIL::ForloopDrop, LiquidIL::TablerowloopDrop
        # Internal drops — trusted, use [] directly
        obj[key]
      when LiquidIL::Drop
        # User drops — security-checked via invoke_drop
        obj.invoke_drop(key)
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
        # Use [] for property access on drops — matches liquid-vm's VariableLookup behavior.
        # This is important because some drops (e.g. ThemeSettingsDrop) override []
        # without overriding invoke_drop, so invoke_drop would miss those overrides.
        if obj.respond_to?(:invoke_drop)
          obj[key.to_s]
        elsif obj.respond_to?(:key?) && obj.respond_to?(:[])
          obj[key.to_s]
        else
          nil
        end
      end

      # to_liquid on the result for nested drops
      result.respond_to?(:to_liquid) ? result.to_liquid : result
    end

    # Lambda wrapper for backward compatibility with generated code
    LOOKUP = method(:lookup)

    def self.call_filter(name, input, args, scope, current_file = nil, line = 1)
      # Try built-in filters first
      if LiquidIL::Filters.valid_filter_methods[name]
        return LiquidIL::Filters.apply(name, input, args, scope)
      end
      # Try custom filters from scope
      if scope.custom_filter?(name)
        return scope.apply_custom_filter(name, input, args)
      end
      # strict_filters: raise on unknown filter
      if scope.strict_filters
        raise LiquidIL::UndefinedFilter, "undefined filter #{name}"
      end
      # Unknown filter — return input unchanged
      input
    rescue LiquidIL::UndefinedFilter
      raise  # Always propagate
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      LiquidIL::ErrorMarker.new(e.message, location)
    end

    # Fast filter call — filter name pre-validated at compile time.
    # Skips name lookup in Filters.apply. Used for filters known to exist.
    def self.call_filter_fast(name, input, args, scope, current_file = nil, line = 1)
      LiquidIL::Filters.apply_fast(name, input, args, scope)
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      LiquidIL::ErrorMarker.new(e.message, location)
    end

    # Custom filter call — dispatches to a custom filter module registered via register_filter.
    # Pure filters get direct dispatch (no scope). Impure filters receive scope.
    def self.call_custom_filter(name, input, args, scope, current_file = nil, line = 1)
      scope.apply_custom_filter(name, input, args)
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      LiquidIL::ErrorMarker.new(e.message, location)
    rescue ArgumentError, Liquid::ArgumentError => e
      raise scope.strict_errors ? e : LiquidIL::FilterRuntimeError.new(LiquidIL.clean_error_message(e.message))
    rescue => e
      raise e if scope.strict_errors || e.is_a?(LiquidIL::FilterRuntimeError)
      raise LiquidIL::FilterRuntimeError.new("internal")
    end

    def self.compare(left, right, op, output = nil, current_file = nil)
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
                   (left.respond_to?(:blank?) && left.blank?) ||
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
                   (right.respond_to?(:blank?) && right.blank?) ||
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

        left_num = to_num(left)
        right_num = to_num(right)

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
    end

    def self.to_num(v)
      case v
      when Integer, Float then v
      when String
        if v =~ /\A-?\d+\z/ then v.to_i
        elsif v =~ /\A-?\d+\.\d+\z/ then v.to_f
        else nil
        end
      else nil
      end
    end

    def self.contains(left, right)
      return false if left.nil? || right.nil?
      case left
      when String then left.include?(right.to_s)
      when Array then left.include?(right)
      when Hash then left.key?(right.to_s) || left.key?(right.to_s.to_sym)
      else false
      end
    end

    def self.to_iterable(value)
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
    end

    def self.slice_collection(collection, from, to)
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
    end

    def self.valid_integer(value)
      return true if value.nil?
      return true if value.is_a?(Integer)
      return true if value.is_a?(Float)
      return true if value.is_a?(String) && value.match?(/\A-?\d/)
      false
    end

    def self.bracket_lookup(obj, key, scope)
      return nil if obj.nil?
      return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)
      key = key.to_liquid_value if key.respond_to?(:to_liquid_value)
      obj = obj.to_liquid if obj.respond_to?(:to_liquid)

      # Set the Liquid::Context on drops so they can access registers, locale, shop, etc.
      obj.context = scope if obj.respond_to?(:context=)

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
      when LiquidIL::ForloopDrop, LiquidIL::TablerowloopDrop
        obj[key]
      when LiquidIL::Drop
        obj.invoke_drop(key)
      else
        if obj.respond_to?(:invoke_drop)
          obj[key.to_s]
        elsif obj.respond_to?(:key?) && obj.respond_to?(:[])
          obj[key.to_s]
        else
          nil
        end
      end
    end

    # Lambda wrappers for backward compatibility
    CALL_FILTER = method(:call_filter)
    COMPARE = method(:compare)
    TO_NUM = method(:to_num)
    CONTAINS = method(:contains)
    TO_ITERABLE = method(:to_iterable)
    SLICE_COLLECTION = method(:slice_collection)
    VALID_INTEGER = method(:valid_integer)
    BRACKET_LOOKUP = method(:bracket_lookup)

    # Read a partial source using Liquid-compatible file system APIs.
    # Supports:
    # - read_template_file(name)
    # - read_template_file(name, context)
    # - read(name) (legacy)
    def self.read_partial_source(file_system, name, context = nil)
      return nil unless file_system

      if file_system.respond_to?(:read_template_file)
        begin
          arity = file_system.method(:read_template_file).arity
          if arity == 1
            file_system.read_template_file(name)
          else
            file_system.read_template_file(name, context)
          end
        rescue NameError
          # Some proxies don't expose #method cleanly; fall back to trial call.
          begin
            file_system.read_template_file(name, context)
          rescue ArgumentError
            file_system.read_template_file(name)
          end
        rescue StandardError
          nil
        end
      elsif file_system.respond_to?(:read)
        begin
          file_system.read(name)
        rescue StandardError
          nil
        end
      end
    end

    # Runtime dynamic partial execution — used when partial name is a variable.
    # Compiles and runs the partial on-the-fly.
    def self.execute_dynamic_partial(name, assigns, output, scope, isolated:, tag_type: "include", caller_line: 1, parent_cycle_state: nil)
      # Validate the name (empty string is allowed here and treated as not-found)
      unless name.is_a?(String)
        message = "Argument error in tag '#{tag_type}' - Illegal template name"
        if scope.render_errors
          location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
          output << "Liquid error (#{location}): #{message}"
          return
        end
        raise LiquidIL::RuntimeError.new(message, file: scope.current_file, line: caller_line)
      end

      fs = scope.file_system
      unless fs
        message = "Could not find partial '#{name}'"
        if scope.render_errors
          location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
          output << "Liquid error (#{location}): #{message}"
          return
        end
        raise LiquidIL::RuntimeError.new(message, file: scope.current_file, line: caller_line)
      end

      # Load source
      source = read_partial_source(fs, name, scope)
      unless source
        message = "Could not find partial '#{name}'"
        if scope.render_errors
          location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
          output << "Liquid error (#{location}): #{message}"
          return
        end
        raise LiquidIL::RuntimeError.new(message, file: scope.current_file, line: caller_line)
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
        pc = compiled.instance_variable_get(:@partial_constants)
        result = if pc
          compiled.instance_variable_get(:@compiled_proc).call(child_scope, compiled.spans, compiled.source, pc)
        else
          compiled.instance_variable_get(:@compiled_proc).call(child_scope, compiled.spans, compiled.source)
        end
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

    # Simple for-loop helper — handles collection prep and offset tracking.
    # Used for loops without ForloopDrop, offset, or limit.
    def self.each_iter(collection, loop_name, scope)
      coll = collection.is_a?(Array) ? collection : to_iterable(collection)
      return if coll.empty?
      coll.each { |item| yield item }
      scope.set_for_offset(loop_name, coll.length)
    end

    # Build paginate object — extracted from generated code to reduce code size
    def self.build_paginate(collection, page_size, current_page)
      total = collection.length
      pages = (total + page_size - 1) / page_size
      pages = 1 if pages < 1
      current_page = [[current_page, 1].max, pages].min
      offset = (current_page - 1) * page_size
      items = collection[offset, page_size] || []
      parts = (1..pages).map { |p| { 'title' => p.to_s, 'url' => "?page=#{p}", 'is_link' => p != current_page } }
      paginate = {
        'page_size' => page_size, 'current_page' => current_page,
        'current_offset' => offset, 'pages' => pages, 'items' => items,
        'parts' => parts,
        'previous' => current_page > 1 ? { 'title' => '&laquo; Previous', 'url' => "?page=#{current_page - 1}", 'is_link' => true } : nil,
        'next' => current_page < pages ? { 'title' => 'Next &raquo;', 'url' => "?page=#{current_page + 1}", 'is_link' => true } : nil,
        'collection_size' => total
      }
      [paginate, items]
    end

    # Regex matching HTML-special characters that need escaping
    NEEDS_ESCAPE_RE = /[&<>"']/

    # Fast HTML escape: returns input unchanged (zero-alloc) when no escaping needed.
    # CGI.escapeHTML always allocates a new String, even for "safe" input.
    def self.escape_html(value)
      return nil if value.nil?
      s = value.is_a?(String) ? value : LiquidIL::Utils.to_s(value)
      s.match?(NEEDS_ESCAPE_RE) ? CGI.escapeHTML(s) : s
    end

    # Format an error from a {{ ... }} output expression, matching liquid-vm behavior.
    # Returns the error message string to append to output.
    def self.output_error(exc, current_file, line, scope)
      raise exc unless scope.render_errors
      raise exc if exc.is_a?(NoMemoryError)
      msg = LiquidIL.clean_error_message(exc.message)
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      "Liquid error (#{location}): #{msg}"
    end

    # Short aliases for generated code compactness (saves ~10% code size)
    class << self
      alias_method :lf, :lookup_prop_fast
      alias_method :lp, :lookup_prop
      alias_method :oa, :output_append
      alias_method :cf, :call_filter
      alias_method :cff, :call_filter_fast
      alias_method :ccf, :call_custom_filter
      alias_method :cmp, :compare
      alias_method :ct, :contains
      alias_method :ti, :to_iterable
      alias_method :sc, :slice_collection
      alias_method :vi, :valid_integer
      alias_method :bl, :bracket_lookup
      alias_method :eh, :escape_html
    end
  end

end
