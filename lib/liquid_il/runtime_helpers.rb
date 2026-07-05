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
    def self.lookup_prop(obj, key)
      # Fast path: avoid to_liquid call for Hash (most common case)
      if obj.is_a?(Hash)
        if SPECIAL_KEYS[key]
          lookup(obj, key)
        else
          obj.fetch(key) { obj[key.to_sym] }
        end
      else
        lookup(obj, key)
      end
    end

    # Fast path for hash property access with non-special keys
    # Skips SPECIAL_KEYS check — caller guarantees key isn't size/length/first/last
    def self.lookup_prop_fast(obj, key)
      if obj.is_a?(Hash)
        # Avoid fetch block allocation: try string key first, sym fallback only if absent
        v = obj[key]
        v.nil? && !obj.key?(key) ? obj[key.to_sym] : v
      else
        lookup(obj, key)
      end
    end

    # Ultra-fast hash lookup — assumes obj is a Hash (no type check)
    # Used for loop variables which are always Hash elements of an Array
    def self.lh(obj, key)
      v = obj[key]
      v.nil? && !obj.key?(key) ? obj[key.to_sym] : v
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
      when Array then output << LiquidIL::Utils.output_string(value)
      when nil then nil
      when true then output << "true"
      when false then output << "false"
      when LiquidIL::ErrorMarker then output << value.to_s
      else output << LiquidIL::Utils.output_string(value)
      end
    end

    # Fused output helpers — one send in generated code where the naive
    # emission needs two or more (~50B of ISeq per fused call site; see
    # docs/win_all_scenarios.md workstream A).
    # olf: output_append(lookup_prop_fast(obj, key))
    def self.olf(output, obj, key)
      output_append(output, lookup_prop_fast(obj, key))
    end

    # olp: output_append after walking a frozen key path
    def self.olp(output, obj, path)
      i = 0
      n = path.length
      while i < n
        obj = lookup_prop_fast(obj, path[i])
        i += 1
      end
      output_append(output, obj)
    end

    # tia: coerce to iterable unless already an Array (for-loop preamble)
    def self.tia(value)
      value.is_a?(Array) ? value : to_iterable(value)
    end

    # ei: simple-loop driver — coerce + iterate, for loops that need no
    # forloop drop, break, limit/offset, or else branch. One emitted block
    # replaces the six-statement while machinery (~190B of ISeq per loop);
    # render cost is identical under YJIT. {% continue %} compiles to
    # `next`, which works inside the yield block.
    def self.ei(collection)
      coll = collection.is_a?(Array) ? collection : to_iterable(collection)
      i = 0
      len = coll.length
      while i < len
        yield coll[i]
        i += 1
      end
    end

    # eif: like ei, but manages the ForloopDrop for bodies that read
    # forloop.* — creation and per-iteration index live in the driver.
    # `break` from the yield block terminates the loop; `next` continues.
    # The index increments AFTER each iteration (reference semantics: a drop
    # assigned out of the loop reads index0 == length after completion, but
    # keeps the current index when the loop exits via {% break %}).
    def self.eif(collection, loop_name, parent)
      coll = collection.is_a?(Array) ? collection : to_iterable(collection)
      return if coll.empty?
      fl = LiquidIL::ForloopDrop.new(loop_name, coll.length, parent)
      i = 0
      len = coll.length
      while i < len
        yield coll[i], fl
        i += 1
        fl.index0 = i
      end
    end

    # eifs: like eif for scope-synced bodies — partial calls inside the loop
    # read the item and forloop through the scope, so each iteration
    # publishes them via assign_local and the previous bindings are restored
    # afterwards. Mirrors the emitted complex-loop protocol exactly: index0
    # is set BEFORE the body, forced to length after the loop (even on
    # {% break %} — hence the ensure), and the loop's offset is recorded for
    # a later `offset: continue`.
    def self.eifs(collection, loop_name, item_name, scope)
      coll = collection.is_a?(Array) ? collection : to_iterable(collection)
      return if coll.empty?
      prev_fl = scope.lookup("forloop")
      prev_item = scope.lookup(item_name)
      fl = LiquidIL::ForloopDrop.new(loop_name, coll.length, prev_fl)
      len = coll.length
      begin
        i = 0
        while i < len
          item = coll[i]
          fl.index0 = i
          i += 1
          scope.assign_local("forloop", fl)
          scope.assign_local(item_name, item)
          yield item, fl
        end
      ensure
        fl.index0 = len
        scope.set_for_offset(loop_name, len)
        scope.assign_local("forloop", prev_fl)
        scope.assign_local(item_name, prev_item)
      end
    end

    # ipc: the single partial-invocation site — builds the partial's scope
    # and wraps the compiled lambda in the invoke_partial prologue/rescue/
    # ensure. Living here (instead of an _H.ip block inside every lambda)
    # saves one nested ISeq per partial.
    def self.ipc(partial, name, assigns, output, scope, isolated, caller_line, cycle_state = nil)
      inner = isolated ? scope.isolated_with(assigns) : scope
      ip(name, scope, isolated, caller_line, output) do
        partial.call(inner, output, isolated, caller_line: caller_line, parent_cycle_state: cycle_state)
      end
    end

    # rpf: driver for {% render 'x' for coll %} — the four-way collection
    # dispatch and per-item forloop drops live in the runtime instead of
    # ~28 emitted lines per call site. Isolated semantics: ranges and
    # enumerables iterate, nil calls once without the item, scalars pass
    # through as the item. Each item's call is separately error-wrapped
    # (one item failing still renders the rest under render_errors).
    def self.rpf(partial, name, item_name, coll, args, output, scope, caller_line, cycle_state = nil)
      items = if coll.is_a?(Array)
        coll
      elsif coll.is_a?(LiquidIL::RangeValue) || coll.is_a?(Range)
        coll.to_a
      elsif !coll.is_a?(Hash) && !coll.is_a?(String) && coll.respond_to?(:each) && coll.respond_to?(:to_a)
        coll.to_a
      else
        args[item_name] = coll unless coll.nil?
        nil
      end
      if items
        len = items.length
        i = 0
        while i < len
          args[item_name] = items[i]
          args["forloop"] = LiquidIL::ForloopDrop.new("forloop", len).tap { |f| f.index0 = i }
          ipc(partial, name, args, output, scope, true, caller_line, cycle_state)
          i += 1
        end
      else
        ipc(partial, name, args, output, scope, true, caller_line, cycle_state)
      end
    end

    # ipf: {% include 'x' for coll %} — include iterates Arrays only (ranges
    # and other enumerables pass through as the item), publishes the item to
    # the caller scope, and stops when the partial sets an interrupt.
    def self.ipf(partial, name, item_name, coll, args, output, scope, caller_line, cycle_state = nil)
      if coll.is_a?(Array)
        coll.each do |item|
          args[item_name] = item
          scope.assign(item_name, item)
          ipc(partial, name, args, output, scope, false, caller_line, cycle_state)
          break if scope.has_interrupt?
        end
      elsif coll.nil?
        ipc(partial, name, args, output, scope, false, caller_line, cycle_state)
      else
        args[item_name] = coll
        scope.assign(item_name, coll)
        ipc(partial, name, args, output, scope, false, caller_line, cycle_state)
      end
    end

    # rolf/rolp: raw text + looked-up value in one send — the raw/lookup/raw
    # sandwich is the most common statement pair in real templates.
    def self.rolf(output, raw, obj, key)
      output << raw
      output_append(output, lookup_prop_fast(obj, key))
    end

    def self.rolp(output, raw, obj, path)
      output << raw
      olp(output, obj, path)
    end

    # roa: raw text + any appended value (variable writes, filter results)
    def self.roa(output, raw, value)
      output << raw
      output_append(output, value)
    end

    # af/afl: assign unless the value is an error marker — replaces the
    # inline `_v = ...; assign unless _v.is_a?(ErrorMarker)` shape (the
    # ErrorMarker constant path alone costs ~30B of ISeq per site).
    def self.af(scope, name, value)
      scope.assign(name, value) unless value.is_a?(LiquidIL::ErrorMarker)
    end

    def self.afl(scope, name, value)
      scope.assign_local(name, value) unless value.is_a?(LiquidIL::ErrorMarker)
    end

    # t: truthy unwrap for conditions — drops define to_liquid_value
    # (BooleanDrop(false) must be falsy). One send instead of the inline
    # _t temp shuffle.
    def self.t(value)
      value.to_liquid_value
    end

    # aff/affl: assign a known-filter result — _H.af(_S, k, _F.ff(...))
    # fused into a single send; the ErrorMarker check lives here.
    #
    # A filter error in an {% assign %} RHS never surfaces into the page:
    # the assignment is abandoned, the target is left untouched, and
    # rendering continues (reference treats assign as a blank tag whose
    # error is recorded, not emitted). In render_errors mode ff hands back
    # an ErrorMarker (skipped below); in raise mode it raises a
    # RuntimeError, which we swallow here so the assign — unlike {{ }}/echo
    # — produces no error text and does not abort the render.
    def self.aff(scope, name, fname, input, args, fscope, file, line)
      v = LiquidIL::Filters.ff(fname, input, args, fscope, file, line)
      scope.assign(name, v) unless v.is_a?(LiquidIL::ErrorMarker)
    rescue LiquidIL::RuntimeError
      nil
    end

    def self.affl(scope, name, fname, input, args, fscope, file, line)
      v = LiquidIL::Filters.ff(fname, input, args, fscope, file, line)
      scope.assign_local(name, v) unless v.is_a?(LiquidIL::ErrorMarker)
    rescue LiquidIL::RuntimeError
      nil
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
      value = value.to_liquid_value
      case value
      when nil, false then false
      when LiquidIL::EmptyLiteral, LiquidIL::BlankLiteral then false
      else true
      end
    }

    def self.lookup(obj, key)
      return nil if obj.nil?

      # Call to_liquid to unwrap drops/proxies before property access
      obj = obj.to_liquid

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
          key_s = key.to_s
          case key_s
          when "size", "length" then obj.length
          when "first" then obj.first
          when "last" then obj.last
          else
            # Index only for numeric keys. A blanket to_i coerced any unknown
            # property name ("class", "secret", ...) to 0 and leaked the
            # first element — reference liquid returns nil here.
            obj[key_s.to_i] if key_s.match?(/\A-?\d+\z/)
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
        when "first" then obj.empty? ? "" : obj[0]
        when "last" then obj.empty? ? "" : obj[-1]
        end
      when Integer
        case key.to_s
        when "size" then obj.size
        end
      else
        # Unknown type — check for Drop-style invoke_drop first (Liquid::Drop compat),
        # then fall back to [] only for Hash-like objects that are known safe.
        if obj.respond_to?(:invoke_drop)
          obj.invoke_drop(key.to_s)
        elsif obj.respond_to?(:liquid_method_missing)
          obj.liquid_method_missing(key.to_s)
        elsif obj.is_a?(Hash) || (obj.respond_to?(:key?) && obj.respond_to?(:[]))
          obj[key.to_s]
        else
          nil
        end
      end

      # to_liquid on the result for nested drops
      result.to_liquid
    end

    # Lambda wrapper for backward compatibility with generated code
    LOOKUP = method(:lookup)

    def self.call_filter(name, input, args, scope, current_file = nil, line = 1)
      # An earlier filter in the chain errored — pass the marker through
      return input if input.is_a?(LiquidIL::ErrorMarker)
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
      raise LiquidIL::RuntimeError.new("Liquid error (#{location}): #{e.message}", file: current_file, line: line) unless scope.render_errors
      LiquidIL::ErrorMarker.new(e.message, location)
    end

    # Fast filter call — filter name pre-validated at compile time.
    # Skips name lookup in Filters.apply. Used for filters known to exist.
    def self.call_filter_fast(name, input, args, scope, current_file = nil, line = 1)
      # An earlier filter in the chain errored — pass the marker through
      return input if input.is_a?(LiquidIL::ErrorMarker)
      LiquidIL::Filters.apply_fast(name, input, args, scope)
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      raise LiquidIL::RuntimeError.new("Liquid error (#{location}): #{e.message}", file: current_file, line: line) unless scope.render_errors
      LiquidIL::ErrorMarker.new(e.message, location)
    end

    # Custom filter call — dispatches to a custom filter module registered via register_filter.
    # Pure filters get direct dispatch (no scope). Impure filters receive scope.
    def self.call_custom_filter(name, input, args, scope, current_file = nil, line = 1)
      # An earlier filter in the chain errored — pass the marker through
      return input if input.is_a?(LiquidIL::ErrorMarker)
      scope.apply_custom_filter(name, input, args)
    rescue LiquidIL::FilterError
      nil
    rescue LiquidIL::FilterRuntimeError => e
      location = current_file ? "#{current_file} line #{line}" : "line #{line}"
      raise LiquidIL::RuntimeError.new("Liquid error (#{location}): #{e.message}", file: current_file, line: line) unless scope.render_errors
      LiquidIL::ErrorMarker.new(e.message, location)
    rescue ArgumentError => e
      raise scope.strict_errors ? e : LiquidIL::FilterRuntimeError.new(e.message)
    rescue => e
      raise e if scope.strict_errors || e.is_a?(LiquidIL::FilterRuntimeError)
      raise LiquidIL::FilterRuntimeError.new("internal")
    end

    def self.compare(left, right, op, output = nil, current_file = nil)
      left = left.to_liquid_value
      right = right.to_liquid_value

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

        if left.is_a?(String) && right.is_a?(String)
          case op
          when :lt then return left < right
          when :le then return left <= right
          when :gt then return left > right
          when :ge then return left >= right
          end
        end

        left_num = to_num(left)
        right_num = to_num(right)

        if left_num.nil? || right_num.nil?
          right_str = right.is_a?(Numeric) ? right.to_s : right.class.to_s
          raise LiquidIL::RuntimeError.new("comparison of #{left.class} with #{right_str} failed", file: current_file, line: 1, partial_output: output&.dup)
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
      return false if left.nil? || right.nil? || right == false
      case left
      when String
        needle = right.to_s
        if left.encoding != needle.encoding
          left = left.dup.force_encoding(Encoding::UTF_8) if left.encoding == Encoding::BINARY && left.valid_encoding?
          needle = needle.dup.force_encoding(left.encoding) if needle.encoding == Encoding::BINARY && needle.valid_encoding?
        end
        left.include?(needle)
      when Array then left.include?(right)
      when Hash then left.key?(right) || (right.is_a?(String) && left.key?(right.to_sym))
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

    def self.bracket_lookup(obj, key)
      return nil if obj.nil?
      return nil if key.is_a?(LiquidIL::RangeValue) || key.is_a?(Range)
      key = key.to_liquid_value
      obj = obj.to_liquid
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
          obj.invoke_drop(key.to_s)
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
    # Read strategy per file_system object. `#method(:read_template_file).arity`
    # allocates a Method every call, and dynamic partials call this once per
    # include *plus* once per dependency revalidation — dozens of throwaway
    # Method objects per render. The arity is stable for a given file_system,
    # so resolve it once and cache by object identity.
    @fs_read_arity = {}.compare_by_identity

    def self.read_partial_source(file_system, name, context = nil)
      return nil unless file_system

      if file_system.respond_to?(:read_template_file)
        arity = @fs_read_arity[file_system]
        if arity.nil?
          arity = begin
            file_system.method(:read_template_file).arity
          rescue NameError
            # Some proxies don't expose #method cleanly; fall back to trial call.
            :trial
          end
          @fs_read_arity[file_system] = arity
        end

        begin
          case arity
          when 1
            file_system.read_template_file(name)
          when :trial
            begin
              file_system.read_template_file(name, context)
            rescue ArgumentError
              file_system.read_template_file(name)
            end
          else
            file_system.read_template_file(name, context)
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

    def self.partial_display_name(name, scope)
      registers = scope.user_registers
      factory = registers && (registers["template_factory"] || registers[:template_factory])
      return name unless factory && factory.respond_to?(:for)

      template = factory.for(name)
      template.respond_to?(:name) && template.name ? template.name : name
    rescue StandardError
      name
    end

    # Partial-lambda wrapper: all per-invocation bookkeeping (current-file
    # tracking, render-depth limit, render_errors recovery) for statically
    # compiled partial lambdas. Hoisted out of the emitted code — this JITs
    # once in the runtime instead of being duplicated into every artifact.
    # The block runs the partial body and appends to `output`.
    def self.invoke_partial(name, scope, isolated, caller_line, output)
      prev_file = scope.current_file
      partial_file = partial_display_name(name, scope)
      scope.current_file = partial_file
      scope.push_render_depth
      if scope.render_depth_exceeded?(strict: !isolated)
        raise LiquidIL::RuntimeError.new("Nesting too deep", file: partial_file, line: caller_line)
      end
      yield
    rescue LiquidIL::ResourceLimitError
      raise  # Resource limits abort the whole render — never recovered inline
    rescue LiquidIL::RuntimeError => e
      raise unless scope.render_errors
      output << (e.partial_output || "")
      location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
      output << "Liquid error (#{location}): #{e.message}"
    rescue LiquidIL::FilterRuntimeError => e
      raise unless scope.render_errors
      output << "Liquid error (#{partial_file} line 1): " << e.message.to_s
    rescue StandardError => e
      raise unless scope.render_errors
      output << "Liquid error (#{partial_file} line 1): " << LiquidIL.clean_error_message(e.message).to_s
    ensure
      scope.current_file = prev_file
      scope.pop_render_depth
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
        message = "This liquid context does not allow includes."
        if scope.render_errors
          location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
          output << "Liquid error (#{location}): #{message}"
          return
        end
        raise LiquidIL::RuntimeError.new(message, file: scope.current_file, line: caller_line)
      end

      # Per-render name→compiled cache. Dynamic includes re-resolve the name to
      # source on every invocation purely to hash it for the process-wide
      # compile cache, so an include inside a loop (product_card × N items)
      # re-reads and re-hashes the same file N times. The file_system is
      # immutable within a single render and `scope` is fresh per render, so a
      # name-keyed cache on the scope lets repeat includes skip the fs read,
      # the hash, and the dep revalidation — while the FIRST include of each
      # name per render still reads + validates, catching cross-render drift.
      name_cache = scope.respond_to?(:dynamic_name_cache) ? (scope.dynamic_name_cache ||= {}) : nil
      cached_template = name_cache && name_cache[name]

      unless cached_template
        # Load source
        source = read_partial_source(fs, name, scope)
        unless source
          message = "Could not find asset #{name}"
          if scope.render_errors
            location = scope.current_file ? "#{scope.current_file} line #{caller_line}" : "line #{caller_line}"
            output << "Liquid error (#{location}): #{message}"
            return
          end
          raise LiquidIL::RuntimeError.new(message, file: scope.current_file, line: caller_line)
        end
      end

      # Compile and execute
      prev_file = scope.current_file
      partial_file = partial_display_name(name, scope)
      scope.current_file = partial_file
      scope.push_render_depth
      if scope.render_depth_exceeded?(strict: isolated)
        scope.current_file = prev_file
        scope.pop_render_depth
        raise LiquidIL::RuntimeError.new("Nesting too deep", file: partial_file, line: 1, partial_output: output.dup)
      end

      begin
        compiled = cached_template || compile_dynamic_partial(source, fs, scope)
        name_cache[name] = compiled if name_cache && !cached_template
        child_scope = isolated ? scope.isolated : scope
        assigns.each { |k, v| child_scope.assign(k, v) }
        child_scope.file_system = fs
        child_scope.render_errors = scope.render_errors
        # Execute the compiled proc directly with the child scope
        pc = compiled.instance_variable_get(:@partial_constants)
        result = if pc
          compiled.instance_variable_get(:@compiled_proc).call(child_scope, pc)
        else
          compiled.instance_variable_get(:@compiled_proc).call(child_scope)
        end
        output << result
      rescue LiquidIL::RuntimeError => e
        raise unless scope.render_errors
        output << (e.partial_output || "")
        location = e.file ? "#{e.file} line #{e.line}" : "line #{e.line}"
        output << "Liquid error (#{location}): #{e.message}"
      rescue LiquidIL::SyntaxError => e
        raise unless scope.render_errors
        message = e.message.to_s.sub(/\ALiquid syntax error \(line \d+\): /, "")
        output << "Liquid syntax error (#{partial_file} line #{e.line}): #{message}"
      rescue => e
        raise unless scope.render_errors
        output << "Liquid error (#{partial_file} line 1): #{LiquidIL.clean_error_message(e.message)}"
      ensure
        scope.current_file = prev_file
        scope.pop_render_depth
      end
    end

    # Process-wide cache of dynamically compiled partials. Dynamic partial
    # names resolve at render time, but the SOURCES are stable — recompiling
    # per render cost 100-800µs where a cache hit costs ~1µs. Keyed by the
    # source string itself (not its .hash): Ruby hashes the key internally at
    # the same cost, but confirms hits with #eql?, so two distinct sources that
    # happen to collide in the 64-bit hash space can never serve one another's
    # compiled template. A hit is only valid while the sources of the nested
    # static partials baked into the compiled body are unchanged (checked
    # against the caller's file_system, so multi-tenant processes can't serve
    # one tenant's nested content to another).
    DYNAMIC_TEMPLATE_CACHE_MAX = 500
    @dynamic_template_cache = {}

    def self.compile_dynamic_partial(source, fs, scope)
      key = source
      entry = @dynamic_template_cache[key]
      if entry
        valid = entry[:deps].all? do |dep_name, dep_source|
          read_partial_source(fs, dep_name, scope) == dep_source
        end
        return entry[:template] if valid
        @dynamic_template_cache.delete(key)
      end

      dyn_ctx = LiquidIL::Context.new(file_system: fs)
      template = dyn_ctx.parse(source)

      # Record the direct static-partial dependencies baked into this body
      deps = {}
      template.instructions&.each do |inst|
        next unless inst[0] == LiquidIL::IL::RENDER_PARTIAL || inst[0] == LiquidIL::IL::INCLUDE_PARTIAL
        args = inst[2] || {}
        next if args["__dynamic_name__"]
        dep_source = read_partial_source(fs, inst[1], scope)
        deps[inst[1]] = dep_source if dep_source
      end

      @dynamic_template_cache.clear if @dynamic_template_cache.size >= DYNAMIC_TEMPLATE_CACHE_MAX
      # Freeze the key so a later in-place mutation of the caller's source
      # string can't silently corrupt the lookup.
      @dynamic_template_cache[key.frozen? ? key : key.dup.freeze] = { template: template, deps: deps }
      template
    end

    # Simple for-loop helper — handles collection prep and offset tracking.
    # Used for loops without ForloopDrop, offset, or limit.
    def self.each_iter(collection, loop_name, scope, &block)
      coll = collection.is_a?(Array) ? collection : to_iterable(collection)
      return if coll.empty?
      coll.each(&block)
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

    def self.render_shopify_section(name, output, scope, caller_file = nil)
      return unless defined?(LiquidIL::ShopifyMock)

      fs = scope.file_system
      return unless fs

      section_name = name.to_s
      assigns = scope.instance_variable_get(:@static_environments) || {}
      section = LiquidIL::ShopifyMock.section_drop(section_name, assigns)
      execute_dynamic_partial("sections/#{section_name}", { "section" => section }, output, scope,
        isolated: false, tag_type: "section", caller_line: 1)
    rescue LiquidIL::RuntimeError => e
      raise unless scope.render_errors
      location = caller_file ? "#{caller_file} line 1" : "line 1"
      output << "Liquid error (#{location}): #{e.message}"
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

    # Short aliases for generated code compactness (saves ~10% code size)
    class << self
      alias_method :lf, :lookup_prop_fast
      alias_method :lp, :lookup_prop
      alias_method :oa, :output_append
      alias_method :ip, :invoke_partial
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
