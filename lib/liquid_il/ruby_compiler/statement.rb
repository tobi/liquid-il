# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Walks statement IL and delegates expressions, loops, partials, filters,
    # and output policy to their focused emitters.
    module StatementEmitter
      private

      # Emit the artifact-local sequence lambdas registered by StatementDedup.
      # Placed after frozen-array constants and before partial lambdas so their
      # bodies (which may reference _fa constants and _H/_F helpers) resolve.
      def generate_sequence_lambdas
        return "" if @sequences.empty?
        code = String.new
        code << "\n  # Deduplicated statement-run lambdas\n"
        @sequences.each do |seq|
          params = seq[:param_locals].join(", ")
          sig = params.empty? ? "->(_O, _S)" : "->(_O, _S, #{params})"
          code << "  #{seq[:name]} = #{sig} {\n"
          # Dual locals for assign targets read back inside the run.
          seq[:dual_slots].each { |slot| code << "    _sqv#{slot}__ = nil\n" }
          code << seq[:body]
          code << "  }\n"
        end
        code
      end

      # Emit a CALL_SEQ site: pass input args by value (through scope_lookup so
      # loop aliases / hoisted locals apply) and target-name args as name strings,
      # and merge the sequence body's recorded effects into the current frame.
      def emit_call_seq(inst, indent)
        seq = @sequences[inst[1]]
        merge_seq_effects(seq[:effects])
        args = inst[2].map do |arg|
          if arg[0] == :input
            arg[2].empty? ? scope_lookup(arg[1]) : generate_var_path_expr(arg[1], arg[2])
          else
            lit(arg[1])
          end
        end
        argstr = args.empty? ? "" : ", #{args.join(", ")}"
        "#{INDENT[indent]}#{seq[:name]}.call(_O, _S#{argstr})\n"
      end

      # Fold a sequence body's effects into the enclosing frame (same merge logic
      # as pop_effects, applied per call site instead of once at compile).
      def merge_seq_effects(child)
        parent = @effects.last
        return unless parent && child
        parent.dynamic ||= child.dynamic
        parent.open_call ||= child.open_call
        parent.uses_parentloop ||= child.uses_parentloop
        (parent.reads ||= Set.new).merge(child.reads) if child.reads
      end

      # Generate the template body
      def generate_body
        @pc = 0
        code = String.new
        instructions = @instructions
        len = instructions.length
        interrupt = @uses_interrupts

        while @pc < len
          inst = instructions[@pc]
          break if inst.nil?

          case inst[0]
          when IL::HALT
            @pc += 1
            break
          when IL::WRITE_RAW
            # Merge consecutive WRITE_RAW instructions into single append.
            # Dup before appending — inst[1] may be frozen (custom passthrough
            # tags) and mutating it in place would corrupt @instructions.
            merged = inst[1]
            while (@pc + 1) < len && instructions[@pc + 1][0] == IL::WRITE_RAW
              merged = merged.dup if merged.equal?(inst[1])
              @pc += 1
              merged << instructions[@pc][1]
            end
            @pc += 1
            if (fused = try_fuse_raw_with_var_path(merged, 1))
              code << fused
            elsif interrupt
              code << "  _O << " << raw_literal_expression(merged) << " unless _S.has_interrupt?\n"
            else
              code << "  _O << " << raw_literal_expression(merged) << "\n"
            end
          when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_SELF
            # Needs peek - delegate to generate_statement
            result = generate_statement(1)
            break if result.nil?
            code << result
          when IL::RENDER_PARTIAL, IL::INCLUDE_PARTIAL
            isolated = inst[0] == IL::RENDER_PARTIAL
            code << generate_partial_call(inst, 1, isolated: isolated)
          when IL::ASSIGN_LOCAL
            @pc += 1
            code << "  _S.assign_local(#{inst[1].inspect}, #{scope_lookup(inst[2])})\n"
          when IL::JUMP_IF_INTERRUPT
            @pc += 1
            code << "  next if _S.has_interrupt?\n"
          when IL::POP_INTERRUPT
            @pc += 1
            # no-op in Ruby compiler
          when IL::JUMP
            target = inst[1]
            # Forward jump: skip dead code, continue at target
            # Backward jump: loop-back, handled by loop structure (no-op)
            @pc = target > @pc ? target : @pc + 1
          when IL::PUSH_SCOPE
            @pc += 1
            code << "  _S.push_scope\n"
          when IL::POP_SCOPE
            @pc += 1
            code << "  _S.pop_scope\n"
          when IL::FOR_INIT
            @pc += 1
            code << "  __for_#{inst[2]}__ = _H.wrap_for_loop(#{generate_var_lookup(inst[1])}, "
            code << "has_limit: #{inst[3]}, has_offset: #{inst[4]})\n"
          when IL::FOR_NEXT
            @pc += 1
            code << "  __for_continue__ = false\n"
          when IL::FOR_END
            @pc += 1
            code << "  end\n"
          when IL::PUSH_FORLOOP
            @pc += 1
            code << "  _S.push_forloop(__for_#{inst[1]}__)\n"
          when IL::POP_FORLOOP
            @pc += 1
            code << "  _S.pop_forloop\n"
          when IL::JUMP_IF_EMPTY
            @pc += 1
            code << "  next if _S.empty?(#{generate_var_lookup(inst[1])})\n"
          when IL::COMPARE
            @pc += 1
            code << "  _S.compare(#{inst[1]}, #{inst[2]}, #{inst[3].inspect})\n"
          when IL::CALL_FILTER
            @pc += 1
            code << "_H.call_filter(#{inst[1].inspect}, "
            args_code = inst[2].map { |a| a.inspect }.join(", ")
            code << args_code << ")\n"
          when IL::WRITE_VALUE
            @pc += 1
            code << "  _O << " << inst[1]
            if interrupt
              code << " unless _S.has_interrupt?\n"
            else
              code << "\n"
            end
          else
            # Detect feature flags during codegen (avoids separate scan pass)
            case inst[0]
            when IL::CYCLE_STEP, IL::CYCLE_STEP_VAR, IL::CONST_INCLUDE, IL::CONST_RENDER
              @uses_cycles = true
            when IL::PUSH_CAPTURE
              @uses_captures = true
            when IL::IFCHANGED_CHECK
              @uses_ifchanged = true
            end
            # Complex cases or unrecognized - delegate
            result = generate_statement(1)
            break if result.nil?
            code << result
          end
        end

        code
      end

      # Generate a single statement, returns Ruby code string
      def generate_statement(indent)
        return nil if @pc >= @instructions.length

        inst = @instructions[@pc]
        return nil if inst.nil?

        prefix = @indent[indent]

        case inst[0]
        when IL::HALT
          @pc += 1
          nil

        when IL::NOOP
          @pc += 1
          ""

        when IL::CALL_SEQ
          @pc += 1
          emit_call_seq(inst, indent)

        when IL::WRITE_RAW
          @pc += 1
          if (fused = try_fuse_raw_with_var_path(inst[1], indent))
            fused
          elsif @uses_interrupts
            %(#{prefix}_O << #{raw_literal_expression(inst[1])} unless _S.has_interrupt?\n)
          else
            %(#{prefix}_O << #{raw_literal_expression(inst[1])}\n)
          end

        when IL::WRITE_VAR
          @pc += 1
          inline_output_append(scope_lookup(inst[1]), prefix, guard_interrupt: @uses_interrupts)

        when IL::WRITE_VAR_PATH
          @pc += 1
          path = inst[2]
          # Fused emission: _H.olf/_H.olp collapse the oa + lf(-chain) sends
          # into one call site (~50B of ISeq each). Only for plain lookups —
          # loop-var aliases and special keys (size/first/...) keep the
          # specialized inline paths. The base stays a textual _S.lookup(...)
          # so the partial-arg rewrites keep matching.
          if !@loop_var_aliases[inst[1]] && path.none? { |k| RuntimeHelpers::SPECIAL_KEYS[k.to_s] }
            record_parentloop_use if inst[1] == "forloop" && path.first.to_s == "parentloop"
            base = scope_lookup_pathed(inst[1])
            guard = @uses_interrupts ? " unless _S.has_interrupt?" : ""
            if path.length == 1
              "#{prefix}_H.olf(_O, #{base}, #{path[0].to_s.inspect})#{guard}\n"
            else
              arr = register_frozen_array(path.map { |k| k.to_s.inspect })
              "#{prefix}_H.olp(_O, #{base}, #{arr})#{guard}\n"
            end
          else
            var_expr = generate_var_path_expr(inst[1], path)
            inline_output_append(var_expr, prefix, guard_interrupt: @uses_interrupts)
          end

        when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_SELF
          case peek_statement_kind
          when :for then generate_for_loop(indent)
          when :tablerow then generate_tablerow(indent)
          when :if then generate_if_statement(indent)
          else generate_expression_statement(indent)
          end

        when IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
             IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK
          case peek_statement_kind
          when :for then generate_for_loop(indent)
          when :tablerow then generate_tablerow(indent)
          when :if then generate_if_statement(indent)
          else generate_expression_statement(indent)
          end

        when IL::IF
          generate_if_statement(indent)

        when IL::FOR_INIT
          generate_for_loop_body(nil, nil, indent)

        when IL::TABLEROW_INIT
          # Tablerow at current position means collection already consumed
          generate_tablerow_body(nil, nil, nil, nil, nil, nil, nil, nil, nil, indent)

        when IL::JUMP
          target = inst[1]
          # Only follow forward jumps to avoid infinite loops
          # Backward jumps are loop-back instructions handled by for_loop
          if target > @pc
            @pc = target
            generate_statement(indent)
          else
            # Backward jump - skip it (handled by loop structure)
            @pc += 1
            ""
          end

        when IL::ASSIGN
          @pc += 1
          # Need to look back for the expression
          @pretty ? "#{prefix}# assign #{inst[1]} (complex)\n" : ""

        when IL::ASSIGN_LOCAL
          @pc += 1
          @pretty ? "#{prefix}# assign_local #{inst[1]} (complex)\n" : ""

        when IL::INCREMENT
          @pc += 1
          var = inst[1]
          # Skip WRITE_VALUE if it follows (we output directly)
          @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
          # Use scope's increment - it handles counter independence and proper lookup integration
          "#{prefix}_O << _S.increment(#{var.inspect}).to_s\n"

        when IL::DECREMENT
          @pc += 1
          var = inst[1]
          # Skip WRITE_VALUE if it follows (we output directly)
          @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
          # Use scope's decrement - it handles counter independence and proper lookup integration
          "#{prefix}_O << _S.decrement(#{var.inspect}).to_s\n"

        when IL::PUSH_SCOPE
          @pc += 1
          "#{prefix}_S.push_scope\n"

        when IL::POP_SCOPE
          @pc += 1
          "#{prefix}_S.pop_scope\n"

        when IL::PUSH_CAPTURE
          @uses_captures = true
          @pc += 1
          "#{prefix}_cst << _O; _O = String.new\n"

        when IL::POP_CAPTURE
          @pc += 1
          # POP_CAPTURE pushes captured value onto stack, followed by ASSIGN or IFCHANGED_CHECK
          # Peek ahead to determine what follows
          if @instructions[@pc]&.[](0) == IL::ASSIGN
            var = @instructions[@pc][1]
            @pc += 1
            "#{prefix}__captured__ = _O; _O = _cst.pop; _S.assign(#{var.inspect}, __captured__)\n"
          elsif @instructions[@pc]&.[](0) == IL::IFCHANGED_CHECK
            @uses_ifchanged = true
            tag_id = @instructions[@pc][1]
            @pc += 1
            # ifchanged: output captured content only if it differs from previous
            code = String.new
            code << "#{prefix}__captured__ = _O; _O = _cst.pop\n"
            code << "#{prefix}if __captured__ != _ics[#{tag_id.inspect}]\n"
            code << "#{prefix}  _ics[#{tag_id.inspect}] = __captured__\n"
            code << "#{prefix}  _O << __captured__\n"
            code << "#{prefix}end\n"
            code
          elsif @instructions[@pc]&.[](0) == IL::CALL_FILTER && @instructions[@pc][2] == 0 &&
                @instructions[@pc + 1]&.[](0) == IL::WRITE_VALUE
            # Capture → filter → output: the custom-tag protocol for tags that
            # transform their captured body (e.g. the mock stylesheet wrapper).
            filter_inst = @instructions[@pc]
            @pc += 2
            filtered = emit_filter_call(filter_inst[1], "__captured__", [], filter_inst[3] || 1)
            "#{prefix}__captured__ = _O; _O = _cst.pop; _H.oa(_O, #{filtered})\n"
          else
            # Fallback - just restore output (captured value is lost)
            "#{prefix}_O = _cst.pop\n"
          end

        when IL::CYCLE_STEP
          @uses_cycles = true
          @pc += 1
          identity = inst[1]
          raw_values = inst[2]
          # Extract actual values from tuples, handle both literals and variables
          # [:lit, value] -> literal value
          # [:var, name] -> runtime variable lookup
          values_ruby = raw_values.map do |v|
            if v.is_a?(Array)
              case v[0]
              when :lit then v[1].inspect
              when :var then scope_lookup(v[1])
              else v.inspect
              end
            else
              v.inspect
            end
          end
          # Skip WRITE_VALUE if it follows (we output directly)
          @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
          # Use __cycle_idx__ to avoid conflict with _x_ in for loops
          # Handle empty values: cycle with 0 choices outputs nothing (empty string)
          if raw_values.empty?
            "#{prefix}_cs[#{identity.inspect}] = (_cs[#{identity.inspect}] || 0) + 1\n"
          else
            "#{prefix}__cycle_idx__ = _cs[#{identity.inspect}] ||= 0; _O << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; _cs[#{identity.inspect}] = __cycle_idx__ + 1\n"
          end

        when IL::CYCLE_STEP_VAR
          @uses_cycles = true
          @pc += 1
          var_name = inst[1]
          raw_values = inst[2]
          # Extract actual values from tuples
          values_ruby = raw_values.map do |v|
            if v.is_a?(Array)
              case v[0]
              when :lit then v[1].inspect
              when :var then scope_lookup(v[1])
              else v.inspect
              end
            else
              v.inspect
            end
          end
          # Skip WRITE_VALUE if it follows (we output directly)
          @pc += 1 if @instructions[@pc]&.[](0) == IL::WRITE_VALUE
          # Identity is a variable - look it up at runtime
          # Handle empty values: cycle with 0 choices outputs nothing (empty string)
          if raw_values.empty?
            "#{prefix}__cycle_key__ = #{scope_lookup(var_name)}; _cs[__cycle_key__] = (_cs[__cycle_key__] || 0) + 1\n"
          else
            "#{prefix}__cycle_key__ = #{scope_lookup(var_name)}; __cycle_idx__ = _cs[__cycle_key__] ||= 0; _O << [#{values_ruby.join(", ")}][__cycle_idx__ % #{raw_values.length}].to_s; _cs[__cycle_key__] = __cycle_idx__ + 1\n"
          end

        when IL::PUSH_INTERRUPT
          # Break/continue: plain Ruby control flow. Every break site is
          # lexically inside its innermost loop (while or an _H.ei/_H.eif
          # yield block — `break` from the block terminates the driver's loop
          # with exactly {% break %} semantics), so no throw/catch bookkeeping
          # is needed. Breaks that cross partial-lambda boundaries use the
          # scope-interrupt protocol instead (the depth-0 path below).
          interrupt_type = inst[1]
          @pc += 1

          code = String.new

          # If break/continue is followed by POP_CAPTURE + ASSIGN, we need to handle
          # capture cleanup. When inside a loop, complete the assignment BEFORE breaking.
          # When outside a loop, just restore output without assigning (discard capture).
          if @instructions[@pc]&.[](0) == IL::POP_CAPTURE &&
             @instructions[@pc + 1]&.[](0) == IL::ASSIGN
            var = @instructions[@pc + 1][1]
            @pc += 2 # Consume POP_CAPTURE and ASSIGN
            if @loop_depth > 0
              # Inside loop: complete the capture assignment before breaking
              code << "#{prefix}__captured__ = _O; _O = _cst.pop; _S.assign(#{var.inspect}, __captured__)\n"
            else
              # Outside loop: just restore output, discard captured content
              code << "#{prefix}_O = _cst.pop\n"
            end
          end

          if @loop_depth > 0
            code << (interrupt_type == :break ? "#{prefix}break\n" : "#{prefix}next\n")
          else
            # Break/continue outside of loop - push interrupt to scope to stop further output
            code << "#{prefix}_S.push_interrupt(#{interrupt_type.inspect})\n"
          end

          code

        when IL::LABEL, IL::POP_INTERRUPT, IL::JUMP_IF_INTERRUPT, IL::POP_FORLOOP,
             IL::FOR_END, IL::FOR_NEXT, IL::JUMP_IF_EMPTY, IL::PUSH_FORLOOP, IL::POP,
             IL::IFCHANGED_CHECK, IL::TABLEROW_NEXT, IL::TABLEROW_END
          @pc += 1
          "" # No-ops in generated Ruby (IFCHANGED_CHECK handled by POP_CAPTURE)

        when IL::LOAD_TEMP
          # Load from temp generates expression - peek ahead to see what follows
          case peek_statement_kind
          when :for then generate_for_loop(indent)
          when :tablerow then generate_tablerow(indent)
          when :if then generate_if_statement(indent)
          else generate_expression_statement(indent)
          end

        when IL::RENDER_PARTIAL
          generate_partial_call(inst, indent, isolated: true)

        when IL::INCLUDE_PARTIAL
          generate_partial_call(inst, indent, isolated: false)

        when :SHOPIFY_SECTION_RENDER
          @pc += 1
          record_open_partial_call
          "#{@indent[indent]}_H.render_shopify_section(#{inst[1].inspect}, _O, _S, #{@current_file_lit.inspect})\n"

        when :PAGINATE_SETUP
          @pc += 1
          coll_path = inst[1]
          page_size = inst[2]
          prefix = @indent[indent]
          # Generate runtime paginate setup using helper method
          parts = coll_path.split(".")
          lookup = scope_lookup(parts[0])
          parts[1..].each { |p| lookup = "_H.l(#{lookup}, #{p.inspect})" }
          # _pgc, not _pc: _pc is the proc's partial-constants parameter
          code = String.new
          code << "#{prefix}_pgc = #{lookup}\n"
          code << "#{prefix}_pgc = _pgc.respond_to?(:to_a) ? _pgc.to_a : Array(_pgc) unless _pgc.is_a?(Array)\n"
          code << "#{prefix}_pg, _pi2 = _H.build_paginate(_pgc, #{page_size}, (_S.lookup('current_page') || 1).to_i)\n"
          code << "#{prefix}_S.assign('paginate', _pg)\n"
          code << "#{prefix}_S.assign(#{parts.last.inspect}, _pi2)\n" if parts.length == 1
          code

        when :PAGINATE_TEARDOWN
          @pc += 1
          ""

        else
          generate_expression_statement(indent)
        end
      end

      # Build expression until we hit STORE_TEMP
      # Generate an expression statement (expression followed by WRITE_VALUE or ASSIGN)
      def generate_expression_statement(indent)
        prefix = @indent[indent]
        @temp_assignments = nil

        # build_expression now returns Ruby string directly (not Expr)
        expr_ruby, terminator = build_expression

        return nil if expr_ruby.nil?

        temp_code = String.new
        if @temp_assignments
          @temp_assignments.each do |slot, temp_ruby|
            temp_code << "#{prefix}__temp_#{slot}__ = #{temp_ruby}\n"
          end
          @temp_assignments = nil
        end

        case terminator
        when :write_value
          temp_code + inline_output_append(expr_ruby, prefix, guard_interrupt: @uses_interrupts)
        when :assign
          var = @instructions[@pc - 1][1]
          emit_assign_statement(var, expr_ruby, prefix, temp_code, local: false)
        when :assign_local
          var = @instructions[@pc - 1][1]
          emit_assign_statement(var, expr_ruby, prefix, temp_code, local: true)
        when :store_temp
          slot = @instructions[@pc][1]
          @pc += 1
          temp_code + "#{prefix}__temp_#{slot}__ = #{expr_ruby}\n"
        else
          temp_code + "#{prefix}#{expr_ruby}\n"
        end
      end

      # Emit an assign statement. `var` is a template name string in the normal
      # case; inside a deduped sequence body it is a SeqRef target, in which case
      # the assign uses the parameter NAME local (_sqp{slot}__) and, when the
      # target is read back inside the run, also binds the dual value local
      # (_sqv{slot}__) — computing the value once and mirroring scope state.
      def emit_assign_statement(var, expr_ruby, prefix, temp_code, local:)
        if var.is_a?(StatementDedup::SeqRef)
          name_l = "_sqp#{var.slot}__"
          af = local ? "afl" : "af"
          if var.dual
            vl = "_sqv#{var.slot}__"
            return temp_code + "#{prefix}#{vl} = #{expr_ruby}\n#{prefix}_H.#{af}(_S, #{name_l}, #{vl})\n"
          elsif expr_ruby.filter_dispatch_inner
            aff = local ? "affl" : "aff"
            return temp_code + "#{prefix}_H.#{aff}(_S, #{name_l}, #{expr_ruby.filter_dispatch_inner})\n"
          else
            return temp_code + "#{prefix}_H.#{af}(_S, #{name_l}, #{expr_ruby})\n"
          end
        end

        # Normal named assign: single known-filter call fuses into one _H.aff send.
        if expr_ruby.filter_dispatch_inner
          aff = local ? "affl" : "aff"
          temp_code + "#{prefix}_H.#{aff}(_S, #{var.inspect}, #{expr_ruby.filter_dispatch_inner})\n"
        else
          af = local ? "afl" : "af"
          temp_code + "#{prefix}_H.#{af}(_S, #{var.inspect}, #{expr_ruby})\n"
        end
      end

      # ── Codegen security invariant ──────────────────────────────
      # All template-derived strings (partial names, tag types, lookup
      # keys, etc.) must be emitted into generated Ruby source ONLY through
      # `lit` (for string literals) or `comment_safe` (for comments).
      # Raw interpolation of template values into emitted code is prohibited
      # — it is an RCE primitive (a malicious name like `evil#{pwn}name`
      # would execute `pwn` at render time). See test/code_injection_test.rb.

      # Emit a template-derived string as a safe Ruby string literal.
      # This is the single codegen primitive for string-literal emission.
      def lit(str)
        s = str.to_s
        src = s.inspect
        # Compiled source is UTF-8, so a bare literal inherits that encoding.
        # Constants that aren't valid UTF-8 (e.g. a folded base64_decode
        # result) must be re-tagged or downstream string ops raise
        # "invalid byte sequence in UTF-8" at render time.
        if s.valid_encoding? && (s.encoding == Encoding::UTF_8 || s.ascii_only?)
          src
        elsif s.encoding == Encoding::BINARY
          "#{src}.b.freeze"
        else
          "#{src}.b.force_encoding(#{s.encoding.name.inspect}).freeze"
        end
      end

      # Escape a template-derived string for safe embedding in a generated
      # Ruby comment. Comments are newline-terminated, so only newlines
      # need escaping to prevent breaking out of the comment.
      def comment_safe(str)
        str.to_s.gsub("\n", "\\n")
      end

      # Generate variable lookup expression
      def generate_var_lookup(expr)
        return "nil" unless expr
        expr_str = expr.to_s

        # Handle string literals
        if expr_str =~ /\A'(.*)'\z/ || expr_str =~ /\A"(.*)"\z/
          return Regexp.last_match(1).inspect
        end

        # Handle range literals
        if expr_str =~ /\A\((-?\d+)\.\.(-?\d+)\)\z/
          return "LiquidIL::RangeValue.new(#{Regexp.last_match(1)}, #{Regexp.last_match(2)})"
        end

        # Parse variable paths with both static and dynamic bracket lookups:
        #   product.title       -> static key "title"
        #   data['my_key']      -> static key "my_key"
        #   data[key]           -> dynamic lookup using key's value
        #   data[config.key]    -> dynamic lookup using a nested expression
        root_match = expr_str.match(/\A[a-zA-Z_]\w*/)
        return "nil" unless root_match

        root = root_match[0]
        result = if root == "self"
          record_dynamic_read
          "_S.lookup_self"
        else
          scope_lookup(root)
        end
        i = root.length

        while i < expr_str.length
          case expr_str.getbyte(i)
          when 46 # .
            i += 1
            key_match = expr_str[i..]&.match(/\A[a-zA-Z_]\w*/)
            break unless key_match
            key = key_match[0]
            result = "_H.lookup(#{result}, #{key.inspect})"
            i += key.length
          when 91 # [
            close = expr_str.index("]", i + 1)
            break unless close
            inner = expr_str[(i + 1)...close].strip
            key_ruby = if inner =~ /\A-?\d+\z/
              inner.to_i.inspect
            elsif (m = inner.match(/\A'(.*)'\z/)) || (m = inner.match(/\A"(.*)"\z/))
              m[1].inspect
            else
              generate_var_lookup(inner)
            end
            result = "_H.lookup(#{result}, #{key_ruby})"
            i = close + 1
          else
            break
          end
        end

        result
      end

      # Expression opcodes a for-loop header may scan through before its
      # JUMP_IF_EMPTY (conditions in limit/offset expressions included).
      PEEK_FOR_OPS = [
        IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
        IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK,
        IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_VAR_DYNAMIC, IL::FIND_SELF,
        IL::NEW_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
        IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::CALL_FILTER, IL::COMPARE, IL::CONTAINS,
        IL::BOOL_NOT, IL::IS_TRUTHY, IL::LOAD_TEMP, IL::CASE_COMPARE
      ].each_with_object({}) { |op, h| h[op] = true }.freeze

      # Expression opcodes allowed before a TABLEROW_INIT.
      PEEK_TABLEROW_OPS = [
        IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_TRUE,
        IL::CONST_FALSE, IL::CONST_NIL, IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK,
        IL::FIND_VAR, IL::FIND_VAR_PATH, IL::FIND_VAR_DYNAMIC, IL::FIND_SELF,
        IL::NEW_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
        IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::CALL_FILTER,
        IL::LOAD_TEMP, IL::DUP
      ].each_with_object({}) { |op, h| h[op] = true }.freeze

      # Opcodes that may sit between JUMP_IF_EMPTY and FOR_INIT (hoisted
      # expressions, limit/offset expressions - including dotted lookups).
      PEEK_FOR_INNER_OPS = [
        IL::FIND_VAR, IL::FIND_VAR_PATH, IL::CONST_INT, IL::CONST_FLOAT,
        IL::CONST_STRING, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_NIL,
        IL::CONST_RANGE, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY,
        IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::NEW_RANGE,
        IL::STORE_TEMP, IL::LOAD_TEMP, IL::DUP
      ].each_with_object({}) { |op, h| h[op] = true }.freeze

      # Classify the statement starting at @pc in ONE forward scan (was three
      # separate peeks re-walking the same span): :for, :tablerow, :if, or nil
      # for a plain expression statement. `f`/`t` track whether every opcode
      # scanned so far is admissible in a for/tablerow header; the IF marker
      # scan is permissive (any opcode continues) with explicit terminators -
      # exactly the semantics the three separate peeks implemented.
      def peek_statement_kind
        insts = @instructions
        i = @pc
        f = t = true
        while (inst = insts[i])
          op = inst[0]
          case op
          when IL::IF
            return :if
          when IL::TABLEROW_INIT
            return t ? :tablerow : nil
          when IL::JUMP_IF_EMPTY
            if f
              j = i + 1
              while (nxt = insts[j])
                return :for if nxt[0] == IL::FOR_INIT
                break unless PEEK_FOR_INNER_OPS[nxt[0]]
                j += 1
              end
            end
            return nil
          when IL::STORE_TEMP
            # Standalone STORE_TEMP ends the statement (e.g. a case/when matched
            # flag); only DUP + STORE_TEMP caching is part of the expression.
            prev = i > 0 ? insts[i - 1] : nil
            return nil unless prev && prev[0] == IL::DUP
          when IL::FOR_INIT, IL::HALT, IL::WRITE_VALUE, IL::WRITE_RAW,
               IL::ASSIGN, IL::ASSIGN_LOCAL, IL::ELSE, IL::END_IF, IL::CALL_SEQ
            # These terminate the expression without being a header
            return nil
          else
            f = false if f && !PEEK_FOR_OPS[op]
            t = false if t && !PEEK_TABLEROW_OPS[op]
          end
          i += 1
        end
        nil
      end

      # Generate an if statement
      # Generate a structured conditional: <condition expr> [:IF, negate]
      # <then statements> [[:ELSE] <else statements>] [:END_IF]. The markers are
      # always properly nested, so this is a plain recursive-descent walk — no
      # jump-target analysis.
      def generate_if_statement(indent)
        prefix = @indent[indent]

        # Build condition expression
        @temp_assignments = nil
        cond_expr, _ = build_expression

        # Emit any temp assignments generated during condition expression building
        # (e.g., DUP + STORE_TEMP caching a variable for reuse in both condition and body)
        temp_code = String.new
        if @temp_assignments
          @temp_assignments.each do |slot, temp_ruby|
            temp_code << "#{prefix}__temp_#{slot}__ = #{temp_ruby}\n"
          end
          @temp_assignments = nil
        end

        # Should now be at the IF marker
        inst = @instructions[@pc]
        return nil unless inst && inst[0] == IL::IF

        negate = inst[1]
        # Slot 2 (set only for :lax blank if/unless constructs): swallow the
        # condition's runtime error text instead of surfacing it, while render!
        # (render_errors=false) still raises. See
        # Parser#mark_blank_error_suppression.
        suppress_errors = inst[2]
        @pc += 1

        then_code = String.new
        else_code = nil

        loop do
          inst = @instructions[@pc]
          break if inst.nil?

          case inst[0]
          when IL::END_IF
            break
          when IL::ELSE
            @pc += 1
            else_code = String.new
            while (else_inst = @instructions[@pc])
              break if else_inst[0] == IL::END_IF
              result = generate_statement(indent + 1)
              break if result.nil?
              else_code << result
            end
            break
          when IL::HALT
            break
          else
            result = generate_statement(indent + 1)
            break if result.nil?
            then_code << result
          end
        end

        # Consume the END_IF marker
        @pc += 1 if @instructions[@pc]&.[](0) == IL::END_IF

        # Generate code
        code = temp_code
        cond_ruby = cond_expr || "nil"
        cond_final = inline_truthy(cond_ruby)
        if suppress_errors
          # Blank + lax: a raising comparison (e.g. 5 > "x") is treated as a
          # false condition and produces no error text under render_errors;
          # render! re-raises so strict rendering is unchanged.
          cond_final = "(begin; #{cond_final}; rescue LiquidIL::RuntimeError; raise unless _S.render_errors; false; end)"
        end

        if negate
          code << "#{prefix}unless #{cond_final}\n"
        else
          code << "#{prefix}if #{cond_final}\n"
        end

        code << then_code

        if else_code && !else_code.empty?
          code << "#{prefix}else\n"
          code << else_code
        end

        code << "#{prefix}end\n"
        code
      end

      # Inline simple filters to avoid Filters.apply dispatch (respond_to? + send)
      # Returns nil if the filter can't be inlined.
      # Register a frozen array constant for compile-time-known filter args.
      # Returns the variable name to use in generated code.
      # Deduplicates: same arg list → same constant.
      # Emit a standard filter dispatch call (cff, cf, or ccf).
      # The "cff" (fast, compile-time-known filter) path is emitted as the
      # flattened single-frame _F.ff dispatcher; cf/ccf stay on _H.
      # Filters that read the ambient (fiber-local) filter context. _F.ff is
      # deliberately state-free — the hot path binds nothing — so these few
      # names route through _H.cff, whose apply_fast binds the context.
    end
  end
end
