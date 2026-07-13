# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Table-driven filter dispatch, immutable operand registration, literal
    # pooling, and property lookup lowering.
    module FilterEmitter
      private

      AMBIENT_CONTEXT_FILTERS = { "read_current_tags" => true, "read_template" => true }.freeze

      def emit_filter_dispatch(dispatcher, name, input, args, line)
        recv = if dispatcher == "cff"
          if AMBIENT_CONTEXT_FILTERS[name]
            "_H.cff"
          else
            require_codegen_helper(:filters)
            "_F.ff"
          end
        else
          "_H.#{dispatcher}"
        end
        inner = if args.empty?
          "#{name.inspect}, #{input}, LiquidIL::EMPTY_ARRAY, _S, #{@current_file_lit.inspect}, #{line}"
        elsif args.all? { |a| a.match?(/\A(?:-?\d+(?:\.\d+)?|"[^"]*")\z/) }
          frozen_name = register_frozen_array(args)
          "#{name.inspect}, #{input}, #{frozen_name}, _S, #{@current_file_lit.inspect}, #{line}"
        else
          "#{name.inspect}, #{input}, [#{args.join(', ')}], _S, #{@current_file_lit.inspect}, #{line}"
        end
        ["#{recv}(#{inner})", recv == "_F.ff" ? inner : nil]
      end

      def register_frozen_array(args)
        key = "[#{args.join(', ')}]".freeze
        name = CodegenSymbols::FROZEN_ARRAYS.intern(key)
        @frozen_arrays[key] = name
        name
      end

      # Generate frozen array constant declarations for top of proc
      def generate_frozen_array_constants
        return "" if @frozen_arrays.empty?
        code = String.new
        @frozen_arrays.each do |literal, name|
          code << "  #{name} = #{literal}.freeze\n"
        end
        code
      end

      # Built-in filters that can never raise for any input (they coerce via
      # Utils.to_s / to_number, or rescue internally). These are safe to call
      # directly on _F — errors are impossible, so no dispatcher wrapper needed.
      #
      # Every OTHER known filter can raise FilterRuntimeError/ArgumentError
      # (to_integer, property selection, division by zero, ...) and MUST go
      # through _H.cff, which converts errors to an ErrorMarker so rendering
      # continues per-statement like reference Liquid. Unknown-at-compile-time
      # filters go through _H.cf (they may be custom filters registered at
      # render time, or unknown → input passthrough).
      SAFE_DIRECT_FILTERS = %w[
        append prepend capitalize downcase upcase strip lstrip rstrip
        strip_html strip_newlines squish newline_to_br
        replace_first replace_last remove remove_first remove_last split
        escape_once url_encode base64_encode base64_url_safe_encode
        plus minus times abs ceil floor round at_least at_most
        size first last join reverse date default
      ].each_with_object({}) { |n, h| h[n] = true }.freeze

      # Integer-literal argument (safe for inline .round(n) etc.)
      INT_LITERAL_RE = /\A-?\d+\z/
      STRING_OUTPUT_FILTERS = %w[
        upcase downcase capitalize strip lstrip rstrip append prepend concat join
        handleize escape_once xml_escape url_encode url_decode newline_to_br
        truncate truncatewords base64_encode base64_url_safe_encode
      ].each_with_object({}) { |name, out| out[name] = true }.freeze
      NUMERIC_OUTPUT_FILTERS = %w[round ceil floor].each_with_object({}) { |name, out| out[name] = true }.freeze

      def emit_filter_call(filter_name, input_ruby, args, line)
        input_fragment = CodeFragment.wrap(input_ruby)
        value_type = if STRING_OUTPUT_FILTERS[filter_name]
          :string
        elsif NUMERIC_OUTPUT_FILTERS[filter_name]
          :numeric
        else
          :unknown
        end

        # Arithmetic filters are not identity operations for Liquid values: even
        # plus:0/times:1 coerce strings to numbers (e.g. "6-3" | plus:0 => 6).
        # A prior dispatch can produce ErrorMarker; the structured may_error bit
        # keeps the rest of that chain in dispatcher-land without inspecting Ruby.
        unless input_fragment.may_error || @context&.prefer_custom_filters?
          if SAFE_DIRECT_FILTERS[filter_name]
            source = if NUMERIC_OUTPUT_FILTERS[filter_name] && args.length > 0 && args.all? { |a| a.match?(INT_LITERAL_RE) }
              "(#{input_fragment} || 0).to_f.#{filter_name}(#{args.join(', ')})"
            elsif args.empty? && INLINE_SIMPLE_FILTERS[filter_name]
              "#{input_fragment}.to_liquid_s.#{filter_name}"
            else
              require_codegen_helper(:filters)
              args.empty? ? "_F.#{filter_name}(#{input_fragment})" : "_F.#{filter_name}(#{input_fragment}, #{args.join(', ')})"
            end
            cache_filter = args.empty? ? FILTER_CACHE[filter_name] && filter_name : nil
            return CodeFragment.new(source, value_type: value_type,
              cache_filter: cache_filter, cache_input: cache_filter ? input_fragment.source : nil)
          end
        end

        source, fusion_inner = if Filters.valid_filter_methods[filter_name] && !@context&.prefer_custom_filters?
          emit_filter_dispatch("cff", filter_name, input_fragment, args, line)
        else
          emit_filter_dispatch("cf", filter_name, input_fragment, args, line)
        end
        CodeFragment.new(source, value_type: value_type, output_policy: :liquid,
          may_error: true, filter_dispatch_inner: fusion_inner)
      end

      # Generate inline property lookup for const string keys (avoids __lookup__ lambda call)
      # Hot path: Hash string key lookup. Falls back to __lookup__ for other types.
      HASH_SPECIAL_KEYS = %w[size length first last].freeze

      # Raw strings at or above this threshold live in the artifact's constants
      # segment rather than the ISeq. A small indexed read is cheaper than loading
      # hundreds of literal bytes on every cold artifact load; short strings stay
      # inline because the extra proc argument/indexing would not pay back.
      LITERAL_POOL_MIN_BYTES = 1024

      def raw_literal_expression(raw)
        return raw.inspect unless @pool_literals && raw.bytesize >= LITERAL_POOL_MIN_BYTES

        index = @literal_indices[raw]
        unless index
          index = @partial_constants.length
          @partial_constants << raw.dup.freeze
          @literal_indices[raw] = index
        end
        "_pc[#{index}]"
      end

      # Fuse WRITE_RAW + following WRITE_VAR / WRITE_VAR_PATH into one runtime
      # send: `_O << "pre"` + `_H.olf(_O, base, "k")` → `_H.rolf(_O, "pre",
      # base, "k")` (~40B of ISeq per site; the raw/lookup/raw sandwich is the
      # most common statement pair in real templates). Consumes the write from
      # the stream on success; same eligibility rules as the olf/olp emission.
      def try_fuse_raw_with_var_path(raw, _indent)
        nxt = @instructions[@pc]
        return nil unless nxt
        guard = @uses_interrupts ? " unless _S.has_interrupt?" : ""

        case nxt[0]
        when IL::WRITE_VAR
          return nil if @loop_var_aliases[nxt[1]]
          @pc += 1
          "  _H.roa(_O, #{raw_literal_expression(raw)}, #{scope_lookup(nxt[1])})#{guard}\n"
        when IL::WRITE_VAR_PATH
          return nil if @loop_var_aliases[nxt[1]]
          path = nxt[2]
          return nil if path.any? { |k| RuntimeHelpers::SPECIAL_KEYS[k.to_s] }

          @pc += 1
          record_parentloop_use if nxt[1] == "forloop" && path.first.to_s == "parentloop"
          base = scope_lookup_pathed(nxt[1])
          if path.length == 1
            "  _H.rolf(_O, #{raw_literal_expression(raw)}, #{base}, #{path[0].to_s.inspect}, _S)#{guard}\n"
          else
            arr = register_frozen_array(path.map { |k| k.to_s.inspect })
            "  _H.rolp(_O, #{raw_literal_expression(raw)}, #{base}, #{arr}, _S)#{guard}\n"
          end
        end
      end

      def inline_lookup(object, key)
        object_fragment = CodeFragment.wrap(object)
        obj_ruby = object_fragment.source
        key_s = key.to_s
        source = if RuntimeHelpers::SPECIAL_KEYS[key_s]
          # Special keys (size/length/first/last) dispatch through the runtime:
          # lookup() knows the per-type semantics (String#first is a byteslice,
          # Arrays/Hashes differ, to_liquid must unwrap first). Inlining these
          # as ternary chains was both bigger (artifact bytes) and wrong for
          # non-collection receivers.
          "_H.lp(#{obj_ruby}, #{key_s.inspect}, _S)"
        elsif object_fragment.origin == :loop_item
          # Loop variable is always a Hash — inline the hash lookup directly
          # Skip symbol fallback for performance (string keys are the common case)
          "#{obj_ruby}[#{key_s.inspect}]"
        else
          "_H.lf(#{obj_ruby}, #{key_s.inspect}, _S)"
        end
        CodeFragment.new(source)
      end

      # Output conversion is driven by CodeFragment metadata. No generated Ruby
      # is re-parsed to infer result type or filter cache requirements.
      INLINE_SIMPLE_FILTERS = {'upcase' => true, 'downcase' => true, 'capitalize' => true, 'strip' => true, 'lstrip' => true, 'rstrip' => true}
      # Cache variable name for each simple filter (per-filter result cache)
      FILTER_CACHE = {
        'capitalize' => '_CAP__',
        'upcase' => '_UP__',
        'downcase' => '_DOWN__',
        'strip' => '_STRIP__',
        'lstrip' => '_LSTRIP__',
        'rstrip' => '_RSTRIP__'
      }
    end
  end
end
