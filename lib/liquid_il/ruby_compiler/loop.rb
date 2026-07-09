# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Lowers for/tablerow IL into native Ruby control flow while recording scope
    # effects for loop-local publication and parentloop planning.
    module LoopEmitter
      private

      # Generate a for loop
      def generate_for_loop(indent)
        prefix = @indent[indent]

        # Build collection expression (handles FIND_VAR, ranges, filter chains, etc.)
        coll_expr, _ = build_expression

        # Should now be at JUMP_IF_EMPTY
        inst = @instructions[@pc]
        return nil unless inst && inst[0] == IL::JUMP_IF_EMPTY

        end_pc = inst[1]
        @pc += 1

        generate_for_loop_body_with_expr(coll_expr, end_pc, indent)
      end

      # Generate for loop body (legacy - called from generate_statement for FOR_INIT at current position)
      def generate_for_loop_body(collection_var, end_pc, indent)
        generate_for_loop_body_with_expr(ruby_var_reference(collection_var || "items"), end_pc, indent)
      end

      # Generate for loop body with expression
      def generate_for_loop_body_with_expr(coll_expr, end_pc, indent)
        prefix = @indent[indent]
        pre_loop_code = String.new

        # First, look ahead to find FOR_INIT and determine offset/limit presence
        # This helps us avoid consuming offset/limit values as pre-loop expressions
        for_init_idx = @pc
        while for_init_idx < @instructions.length && @instructions[for_init_idx][0] != IL::FOR_INIT
          for_init_idx += 1
        end

        has_limit = false
        has_offset = false
        if for_init_idx < @instructions.length
          fi = @instructions[for_init_idx]
          has_limit = fi[3]
          has_offset = fi[4]
        end

        # Count how many values need to be on stack for offset/limit
        values_needed = (has_offset ? 1 : 0) + (has_limit ? 1 : 0)

        # Skip any pre-loop hoisted expressions (FIND_VAR + STORE_TEMP patterns).
        # Everything else before FOR_INIT is offset/limit values — leave for
        # build_single_value_expression to consume.
        while @pc < @instructions.length && @instructions[@pc][0] != IL::FOR_INIT
          inst = @instructions[@pc]
          case inst[0]
          when IL::FIND_VAR
            next_inst = @instructions[@pc + 1]
            if next_inst && next_inst[0] == IL::STORE_TEMP
              var_name = inst[1]
              slot = next_inst[1]
              @pc += 2
              pre_loop_code << "#{prefix}__temp_#{slot}__ = #{scope_lookup(var_name)}\n"
            else
              break  # offset/limit expression starts here
            end
          when IL::STORE_TEMP
            @pc += 1
          else
            break  # offset/limit expression starts here
          end
        end

        # Handle offset/limit expressions if present (pushed onto stack before FOR_INIT)
        # IL emits: offset, limit (in that order) so we read offset first, then limit
        limit_expr = nil
        offset_expr = nil

        if for_init_idx < @instructions.length
          # Build offset expression if present (emitted first in IL)
          if has_offset && @pc < for_init_idx
            offset_expr = build_single_value_expression
          end

          # Build limit expression if present (emitted second in IL)
          if has_limit && @pc < for_init_idx
            limit_expr = build_single_value_expression
          end
        end

        # Consume: FOR_INIT
        for_init = @instructions[@pc]
        return nil unless for_init && for_init[0] == IL::FOR_INIT

        item_var = for_init[1]
        loop_name = for_init[2]
        has_limit = for_init[3]
        has_offset = for_init[4]
        offset_continue = for_init[5]
        reversed = for_init[6]
        # Slot 8 (set only for :lax blank for-loops): suppress the offset/limit
        # "invalid integer" error text in the recovery rescue. See parse_for_tag.
        suppress_errors = for_init[8]
        @pc += 1

        # Track loop depth for nested loops - increment BEFORE parsing body.
        # Naming uses @loop_name_base so a partial body INLINED into another
        # template's loop can't collide with the call site's loop locals
        # (each partial compilation gets a unique base; see compile_partial).
        depth = @loop_name_base + @loop_depth
        @loop_depth += 1

        # Skip structural instructions
        while @pc < @instructions.length
          case @instructions[@pc][0]
          when IL::PUSH_SCOPE, IL::PUSH_FORLOOP, IL::FOR_NEXT
            @pc += 1
          when IL::ASSIGN_LOCAL
            if @instructions[@pc][1] == item_var
              @pc += 1
            else
              break
            end
          else
            break
          end
        end

        # Parse loop body — set up aliases so expression lowering can resolve
        # loop vars to Ruby locals instead of _S.lookup() calls.
        saved_aliases = {}
        alias_names = { item_var => "_i#{depth}__", "forloop" => "_fl#{depth}__" }
        alias_names.each do |liq_var, ruby_var|
          saved_aliases[liq_var] = @loop_var_aliases[liq_var]
          @loop_var_aliases[liq_var] = ruby_var
        end

        # Body emitters record scope effects into this frame; the sync
        # decision below reads it instead of scanning body_code.
        push_effects

        body_start = @pc
        body_code = String.new

        while @pc < @instructions.length
          inst = @instructions[@pc]
          break if inst.nil?

          case inst[0]
          when IL::JUMP
            # Check if jumping back (end of loop)
            if inst[1] <= body_start || @instructions[@pc + 1]&.[](0) == IL::POP_INTERRUPT
              @pc += 1
              break
            else
              result = generate_statement(indent + 3)
              break if result.nil?
              body_code << result
            end
          when IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END
            # These mark end of loop body - don't consume, let cleanup handle them
            # Note: JUMP_IF_INTERRUPT is NOT included because it appears mid-body after break/continue
            break
          when IL::HALT
            break
          else
            result = generate_statement(indent + 3)
            break if result.nil?
            body_code << result
          end
        end

        # Restore previous aliases (handles nested loops correctly)
        saved_aliases.each do |liq_var, prev|
          if prev
            @loop_var_aliases[liq_var] = prev
          else
            @loop_var_aliases.delete(liq_var)
          end
        end

        body_effects = pop_effects

        # Consume cleanup and detect for-else pattern
        else_end_target = nil
        while @pc < @instructions.length
          inst = @instructions[@pc]
          case inst&.[](0)
          when IL::POP_INTERRUPT, IL::POP_FORLOOP, IL::POP_SCOPE, IL::FOR_END, IL::LABEL
            @pc += 1
          when IL::JUMP
            # If this JUMP targets past end_pc, there's an else block
            if end_pc && inst[1] > end_pc
              else_end_target = inst[1]
            end
            @pc += 1
          else
            break
          end
        end

        # Parse else block if present (between end_pc and else_end_target)
        else_code = String.new
        if else_end_target && end_pc && @pc == end_pc
          while @pc < else_end_target
            inst = @instructions[@pc]
            break if inst.nil? || inst[0] == IL::HALT
            result = generate_statement(indent + 1)
            break if result.nil?
            else_code << result
          end
        end

        # Generate the loop code with unique variable names for nested loops
        code = String.new
        code << pre_loop_code unless pre_loop_code.empty?
        coll_ruby = coll_expr || "nil"

        # Use depth-indexed variables for forloop and collection
        forloop_var = "_fl#{depth}__"
        coll_var = "_c#{depth}__"
        item_var_internal = "_i#{depth}__"
        idx_var = "_x#{depth}__"

        # Decide from the body's recorded effects (not its text): sync when
        # something in the body reads the item or forloop through the scope —
        # open partial calls (include/dynamic/section) read arbitrary names
        # at render time, dynamic reads ({{ [v] }}, {{ self }}) resolve names
        # at render time, and nested scope-reading loops propagate up.
        # Isolated {% render %} calls set no flag: they cannot see caller
        # locals, and their arg expressions resolve through loop-var aliases.
        needs_scope_sync = body_effects.open_call ||
                           body_effects.dynamic ||
                           (body_effects.reads&.include?("forloop")) ||
                           (body_effects.reads&.include?(item_var)) || false
        needs_forloop = body_effects.uses_forloop || needs_scope_sync
        needs_error_handling = has_offset || has_limit
        needs_slicing = limit_expr || offset_expr || offset_continue

        # Parent-forloop reference for this loop's drop. Only observable
        # through forloop.parentloop (or when the drop escapes to scope
        # readers under sync), so pass nil otherwise. Emitted AFTER the
        # body's aliases are restored: inside an enclosing loop this
        # resolves to the enclosing drop's local directly — no scope read,
        # no sync forced on the enclosing loop.
        parent_forloop = if body_effects.uses_parentloop || needs_scope_sync
          scope_lookup("forloop")
        else
          "nil"
        end

        # eifs reads the previous item/forloop bindings through the scope
        # (publish + restore protocol) — the enclosing loop must have
        # published its own. The complex sync path does the same manually.
        if needs_scope_sync
          record_scope_read("forloop")
          record_scope_read(item_var)
        end

        # Fast path: simple and forloop-bearing loops emit one _H.ei/_H.eif
        # block — the driver (coerce, length, index walk, ForloopDrop
        # management) lives in the already-jitted runtime, saving ~190B+ of
        # ISeq per loop vs the inline while machinery; render cost is
        # identical under YJIT. Plain Ruby control flow does the rest:
        # {% continue %} is `next`, {% break %} is `break` — a break from the
        # yield block terminates the driver's loop with exactly the right
        # semantics, no throw/catch bookkeeping.
        if !needs_error_handling &&
           !reversed && !needs_slicing && !offset_continue && else_code.empty?
          if needs_scope_sync
            # Scope-synced bodies (partial calls read the item/forloop through
            # the scope): _H.eifs publishes them per iteration and restores the
            # previous bindings — the whole prep/sync/restore protocol lives in
            # the runtime instead of ~14 emitted lines per loop.
            code << "#{prefix}_H.eifs(#{coll_ruby}, #{loop_name.inspect}, #{item_var.inspect}, _S) do |#{item_var_internal}, #{forloop_var}|\n"
          elsif needs_forloop
            code << "#{prefix}_H.eif(#{coll_ruby}, #{loop_name.inspect}, #{parent_forloop}) do |#{item_var_internal}, #{forloop_var}|\n"
          else
            code << "#{prefix}_H.ei(#{coll_ruby}) do |#{item_var_internal}|\n"
          end
          if @has_resource_limits
            code << "#{prefix}  _S.increment_render_score!\n"
            code << "#{prefix}  _S.check_output_limit!(_O)\n"
          end
          # body_code is at INDENT[indent+3], needs INDENT[indent+1] (strip 4
          # spaces) — cosmetic only, so skip the full-body gsub outside pretty mode
          # (compact_source strips leading whitespace before the ISeq anyway).
          code << (@pretty ? body_code.gsub(/^#{Regexp.escape(prefix)}      /, prefix + "  ") : body_code)
          code << "#{prefix}end\n"
          @loop_depth -= 1
          return code
        end

        # Complex path: full collection prep with offset/limit/slicing support
        code << "#{prefix}begin\n" if needs_error_handling
        inner_prefix = needs_error_handling ? "#{prefix}  " : prefix

        if needs_slicing || has_offset || has_limit
          code << "#{inner_prefix}_oc#{depth}__ = #{coll_ruby}\n"
          code << "#{inner_prefix}_is#{depth}__ = _oc#{depth}__.is_a?(String)\n"
          code << "#{inner_prefix}_in#{depth}__ = _oc#{depth}__.nil? || _oc#{depth}__ == false\n"
          code << "#{inner_prefix}#{coll_var} = _H.tia(_oc#{depth}__)\n"
        else
          code << "#{inner_prefix}#{coll_var} = #{coll_ruby}\n"
          code << "#{inner_prefix}#{coll_var} = _H.tia(#{coll_var})\n"
        end

        offset_var = "_so#{depth}__"
        if offset_continue
          code << "#{inner_prefix}#{offset_var} = _S.for_offset(#{loop_name.inspect})\n"
        elsif offset_expr
          offset_ruby = offset_expr
          if has_offset
            code << "#{inner_prefix}_ov#{depth}__ = #{offset_ruby}\n"
            code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _in#{depth}__ || _H.vi(_ov#{depth}__)\n"
            code << "#{inner_prefix}#{offset_var} = _ov#{depth}__.to_i\n"
          else
            code << "#{inner_prefix}#{offset_var} = (#{offset_ruby}).to_i\n"
          end
        else
          code << "#{inner_prefix}#{offset_var} = 0\n"
        end

        needs_slicing = limit_expr || offset_expr || offset_continue
        if limit_expr
          limit_ruby = limit_expr
          if has_limit
            code << "#{inner_prefix}_lv#{depth}__ = #{limit_ruby}\n"
            code << "#{inner_prefix}raise LiquidIL::RuntimeError.new(\"invalid integer\", file: #{@current_file_lit.inspect}, line: 1) unless _in#{depth}__ || _H.vi(_lv#{depth}__)\n"
            code << "#{inner_prefix}_to#{depth}__ = #{offset_var} + _lv#{depth}__.to_i\n"
          else
            code << "#{inner_prefix}_to#{depth}__ = #{offset_var} + (#{limit_ruby}).to_i\n"
          end
          code << "#{inner_prefix}#{coll_var} = _H.sc(#{coll_var}, #{offset_var}, _to#{depth}__) unless _is#{depth}__\n"
        elsif needs_slicing
          code << "#{inner_prefix}#{coll_var} = _H.sc(#{coll_var}, #{offset_var}, nil) unless _is#{depth}__\n"
        end

        code << "#{inner_prefix}#{coll_var} = #{coll_var}.reverse\n" if reversed

        code << "#{inner_prefix}if !#{coll_var}.empty?\n"
        if needs_forloop
          code << "#{inner_prefix}  #{forloop_var} = LiquidIL::ForloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{parent_forloop})\n"
        end
        # Save previous values for scope cleanup after loop
        if needs_scope_sync
          code << "#{inner_prefix}  _pfl#{depth}__ = _S.lookup('forloop')\n"
        end
        code << "#{inner_prefix}  _pi#{depth}__ = _S.lookup(#{item_var.inspect})\n" if needs_scope_sync
        if needs_forloop
          # Use while loop instead of each_with_index block — avoids block yield overhead
          code << "#{inner_prefix}    #{idx_var} = 0\n"
          code << "#{inner_prefix}    #{coll_var}_len = #{coll_var}.length\n"
          code << "#{inner_prefix}    while #{idx_var} < #{coll_var}_len\n"
          code << "#{inner_prefix}      #{item_var_internal} = #{coll_var}[#{idx_var}]\n"
          code << "#{inner_prefix}      #{forloop_var}.index0 = #{idx_var}\n"
          # Increment BEFORE the body: `next` (continue / interrupt checks) would
          # skip a trailing increment and loop forever.
          code << "#{inner_prefix}      #{idx_var} += 1\n"
        else
          # No forloop needed — use plain each (skip index tracking overhead)
          code << "#{inner_prefix}    #{coll_var}.each do |#{item_var_internal}|\n"
        end
        if needs_scope_sync
          code << "#{inner_prefix}      _S.assign_local('forloop', #{forloop_var})\n"
          code << "#{inner_prefix}      _S.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
        end
        # Resource limit checks — only emitted when limits are configured
        if @has_resource_limits
          code << "#{inner_prefix}      _S.increment_render_score!\n"
          code << "#{inner_prefix}      _S.check_output_limit!(_O)\n"
        end
        # Adjust body_code indentation if we have error handling (cosmetic only)
        if needs_error_handling && @pretty
          body_code = body_code.gsub(/^/, "  ")
        end
        code << body_code
        code << "#{inner_prefix}    end\n"
        if needs_forloop
          code << "#{inner_prefix}  #{forloop_var}.index0 = #{coll_var}.length\n"
        end
        code << "#{inner_prefix}  _S.set_for_offset(#{loop_name.inspect}, #{offset_var} + #{coll_var}.length)\n"
        if needs_scope_sync
          code << "#{inner_prefix}  _S.assign_local('forloop', _pfl#{depth}__)\n"
          code << "#{inner_prefix}  _S.assign_local(#{item_var.inspect}, _pi#{depth}__)\n"
        end

        # Add else block if present (for-else pattern)
        if !else_code.empty?
          code << "#{inner_prefix}else\n"
          # Adjust else_code indentation if we have error handling (cosmetic only)
          if needs_error_handling && @pretty
            else_code = else_code.gsub(/^/, "  ")
          end
          code << else_code
        end

        code << "#{inner_prefix}end\n"

        # Close error handling block
        if needs_error_handling
          code << "#{prefix}rescue LiquidIL::RuntimeError => _e#{depth}__\n"
          code << "#{prefix}  raise unless _S.render_errors\n"
          unless suppress_errors
            code << "#{prefix}  _loc#{depth}__ = _e#{depth}__.file ? \"\#{_e#{depth}__.file} line \#{_e#{depth}__.line}\" : \"line \#{_e#{depth}__.line}\"\n"
            code << "#{prefix}  _O << \"Liquid error (\#{_loc#{depth}__}): \#{_e#{depth}__.message}\"\n"
          end
          code << "#{prefix}end\n"
        end

        @loop_depth -= 1
        code
      end

      # Generate a tablerow loop (called when FIND_VAR starts a tablerow sequence)
      def generate_tablerow(indent)
        record_dynamic_read
        prefix = @indent[indent]

        # Scan forward to find TABLEROW_INIT and determine what params it has
        tablerow_init_idx = @pc
        while tablerow_init_idx < @instructions.length && @instructions[tablerow_init_idx][0] != IL::TABLEROW_INIT
          tablerow_init_idx += 1
        end

        return nil if tablerow_init_idx >= @instructions.length

        tablerow_init = @instructions[tablerow_init_idx]
        item_var = tablerow_init[1]
        loop_name = tablerow_init[2]
        has_limit = tablerow_init[3]
        has_offset = tablerow_init[4]
        cols = tablerow_init[5]  # nil, :dynamic, :explicit_nil, or integer

        # IL stack order: collection, limit (if has_limit), offset (if has_offset), cols (if :dynamic)
        # We need to read them in that order
        # Use build_single_value_expression to read ONE value at a time

        # Read collection expression
        coll_expr = build_single_value_expression

        # Read limit expression if present
        limit_expr = nil
        if has_limit && @pc < tablerow_init_idx
          limit_expr = build_single_value_expression
        end

        # Read offset expression if present
        offset_expr = nil
        if has_offset && @pc < tablerow_init_idx
          offset_expr = build_single_value_expression
        end

        # Read cols expression if dynamic
        cols_expr = nil
        if cols == :dynamic && @pc < tablerow_init_idx
          cols_expr = build_single_value_expression
        end

        # Handle any hoisted FIND_VAR + STORE_TEMP patterns before TABLEROW_INIT
        pre_loop_code = String.new
        while @pc < tablerow_init_idx
          inst = @instructions[@pc]
          case inst[0]
          when IL::FIND_VAR
            next_inst = @instructions[@pc + 1]
            if next_inst && next_inst[0] == IL::STORE_TEMP
              var_name = inst[1]
              slot = next_inst[1]
              @pc += 2
              pre_loop_code << "#{"  " * indent}__temp_#{slot}__ = #{scope_lookup(var_name)}\n"
            else
              break
            end
          when IL::STORE_TEMP
            @pc += 1
          else
            break
          end
        end

        # Move to TABLEROW_INIT and consume it
        @pc = tablerow_init_idx + 1

        code = pre_loop_code
        code << generate_tablerow_body(coll_expr, limit_expr, offset_expr, cols_expr, cols, has_limit, has_offset, item_var, loop_name, indent).to_s
        code
      end

      # Generate tablerow body (called when expressions already built or at TABLEROW_INIT)
      def generate_tablerow_body(coll_expr, limit_expr, offset_expr, cols_expr, cols, has_limit, has_offset, item_var, loop_name, indent)
        prefix = @indent[indent]

        # If called directly from TABLEROW_INIT, get params from instruction
        if coll_expr.nil?
          tablerow_init = @instructions[@pc]
          return nil unless tablerow_init && tablerow_init[0] == IL::TABLEROW_INIT

          item_var = tablerow_init[1]
          loop_name = tablerow_init[2]
          has_limit = tablerow_init[3]
          has_offset = tablerow_init[4]
          cols = tablerow_init[5]
          @pc += 1
          coll_expr = ruby_var_reference("items")
        end

        # Track loop depth for nested loops (naming offset by @loop_name_base —
        # see generate_for_loop)
        depth = @loop_name_base + @loop_depth
        @loop_depth += 1

        # Skip structural instructions (PUSH_SCOPE, TABLEROW_NEXT)
        while @pc < @instructions.length
          case @instructions[@pc][0]
          when IL::PUSH_SCOPE, IL::TABLEROW_NEXT, IL::LABEL
            @pc += 1
          when IL::ASSIGN_LOCAL
            if @instructions[@pc][1] == item_var
              @pc += 1
            else
              break
            end
          else
            break
          end
        end

        # Parse loop body
        body_start = @pc
        body_code = String.new

        while @pc < @instructions.length
          inst = @instructions[@pc]
          break if inst.nil?

          case inst[0]
          when IL::JUMP
            # Check if jumping back (end of loop)
            if inst[1] <= body_start || @instructions[@pc + 1]&.[](0) == IL::POP_INTERRUPT
              @pc += 1
              break
            else
              result = generate_statement(indent + 3)
              break if result.nil?
              body_code << result
            end
          when IL::POP_INTERRUPT, IL::POP_SCOPE, IL::TABLEROW_END
            # These mark end of loop body
            break
          when IL::HALT
            break
          else
            result = generate_statement(indent + 3)
            break if result.nil?
            body_code << result
          end
        end

        # Consume cleanup instructions (including loop-back JUMPs)
        while @pc < @instructions.length
          inst = @instructions[@pc]
          case inst&.[](0)
          when IL::POP_INTERRUPT, IL::POP_SCOPE, IL::TABLEROW_END, IL::LABEL, IL::JUMP_IF_INTERRUPT
            @pc += 1
          when IL::JUMP
            # Backward jumps are loop-back instructions, consume them
            if inst[1] < @pc
              @pc += 1
            else
              break
            end
          else
            break
          end
        end

        # Generate the tablerow code
        code = String.new
        coll_var = "__tablerow_coll_#{depth}__"
        tablerowloop_var = "__tablerowloop_#{depth}__"
        item_var_internal = "__tablerow_item_#{depth}__"
        idx_var = "__tablerow_idx_#{depth}__"
        cols_var = "__tablerow_cols_#{depth}__"
        coll_ruby = coll_expr || "nil"

        code << "#{prefix}__orig_tablerow_coll_#{depth}__ = #{coll_ruby}\n"
        code << "#{prefix}_is#{depth}__ = __orig_tablerow_coll_#{depth}__.is_a?(String)\n"
        code << "#{prefix}_in#{depth}__ = __orig_tablerow_coll_#{depth}__.nil? || __orig_tablerow_coll_#{depth}__ == false\n"
        code << "#{prefix}#{coll_var} = _H.ti(__orig_tablerow_coll_#{depth}__)\n"

        # Handle cols parameter
        case cols
        when :dynamic
          if cols_expr
            code << "#{prefix}__cols_val_#{depth}__ = #{cols_expr}\n"
            code << "#{prefix}if __cols_val_#{depth}__.nil?\n"
            code << "#{prefix}  #{cols_var} = #{coll_var}.length\n"
            code << "#{prefix}  __cols_explicit_nil_#{depth}__ = true\n"
            code << "#{prefix}elsif _in#{depth}__\n"
            code << "#{prefix}  #{cols_var} = 1\n"
            code << "#{prefix}  __cols_explicit_nil_#{depth}__ = false\n"
            code << "#{prefix}else\n"
            code << "#{prefix}  #{cols_var} = _H.tri(__cols_val_#{depth}__, #{@current_file_lit.inspect}, 1)\n"
            code << "#{prefix}  # cols <= 0 (e.g. a non-numeric string coerced by to_i) never wraps\n"
            code << "#{prefix}  # in reference — one row, like no cols at all\n"
            code << "#{prefix}  #{cols_var} = #{coll_var}.length if #{cols_var} <= 0\n"
            code << "#{prefix}  __cols_explicit_nil_#{depth}__ = false\n"
            code << "#{prefix}end\n"
          else
            code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
            code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
          end
        when :explicit_nil
          code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
          code << "#{prefix}__cols_explicit_nil_#{depth}__ = true\n"
        when nil
          code << "#{prefix}#{cols_var} = #{coll_var}.length\n"
          code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
        else
          code << "#{prefix}#{cols_var} = #{cols}\n"
          code << "#{prefix}__cols_explicit_nil_#{depth}__ = false\n"
        end

        # Handle offset if present (validate and apply) - for strings, offset is ignored
        # Note: offset must be applied BEFORE limit (VM order)
        # Skip all processing if collection is nil/false (no output will be generated anyway)
        if has_offset
          if offset_expr
            offset_ruby = offset_expr
            code << "#{prefix}_ov#{depth}__ = #{offset_ruby}\n"
            code << "#{prefix}unless _in#{depth}__\n"
            code << "#{prefix}  __offset_#{depth}__ = _H.tri(_ov#{depth}__, #{@current_file_lit.inspect}, 1)\n"
            code << "#{prefix}  __offset_#{depth}__ = [__offset_#{depth}__, 0].max\n"
            code << "#{prefix}  #{coll_var} = #{coll_var}.drop(__offset_#{depth}__) unless _is#{depth}__\n"
            code << "#{prefix}end\n"
          end
        end

        # Handle limit if present (validate and apply) - for strings, limit is ignored
        # nil limit means take 0 items for tablerow (different from for loop)
        # Skip all processing if collection is nil/false (no output will be generated anyway)
        if has_limit
          if limit_expr
            limit_ruby = limit_expr
            code << "#{prefix}_lv#{depth}__ = #{limit_ruby}\n"
            code << "#{prefix}unless _in#{depth}__\n"
            code << "#{prefix}  __limit_#{depth}__ = _H.tri(_lv#{depth}__, #{@current_file_lit.inspect}, 1)\n"
            code << "#{prefix}  __limit_#{depth}__ = 0 if __limit_#{depth}__ < 0\n"
            code << "#{prefix}  #{coll_var} = #{coll_var}.take(__limit_#{depth}__) unless _is#{depth}__\n"
            code << "#{prefix}end\n"
          end
        end

        # Ensure cols is at least 1 to avoid division by zero
        code << "#{prefix}#{cols_var} = [#{cols_var}, 1].max\n"

        code << "#{prefix}_S.push_scope\n"
        code << "#{prefix}#{tablerowloop_var} = LiquidIL::TablerowloopDrop.new(#{loop_name.inspect}, #{coll_var}.length, #{cols_var}, nil, __cols_explicit_nil_#{depth}__)\n"

        # Output opening row tag for empty collections
        code << "#{prefix}  if #{coll_var}.empty? && !_in#{depth}__\n"
        code << "#{prefix}    _O << \"<tr class=\\\"row1\\\">\\n\"\n"
        code << "#{prefix}    _O << \"</tr>\\n\"\n"
        code << "#{prefix}  end\n"

        code << "#{prefix}  #{coll_var}.each_with_index do |#{item_var_internal}, #{idx_var}|\n"
        code << "#{prefix}    #{tablerowloop_var}.index0 = #{idx_var}\n"
        code << "#{prefix}    _S.assign_local('tablerowloop', #{tablerowloop_var})\n"
        code << "#{prefix}    _S.assign_local(#{item_var.inspect}, #{item_var_internal})\n"
        if @has_resource_limits
          code << "#{prefix}    _S.increment_render_score!\n"
          code << "#{prefix}    _S.check_output_limit!(_O)\n"
        end

        # Output HTML tags before body content
        code << "#{prefix}    if #{idx_var} > 0\n"
        code << "#{prefix}      _O << \"</td>\"\n"
        code << "#{prefix}      if (#{idx_var} % #{cols_var}) == 0\n"
        code << "#{prefix}        _O << \"</tr>\\n\"\n"
        code << "#{prefix}      end\n"
        code << "#{prefix}    end\n"

        code << "#{prefix}    if (#{idx_var} % #{cols_var}) == 0\n"
        code << "#{prefix}      __row__ = (#{idx_var} / #{cols_var}) + 1\n"
        code << "#{prefix}      if __row__ == 1\n"
        code << "#{prefix}        _O << \"<tr class=\\\"row\#{__row__}\\\">\\n\"\n"
        code << "#{prefix}      else\n"
        code << "#{prefix}        _O << \"<tr class=\\\"row\#{__row__}\\\">\"\n"
        code << "#{prefix}      end\n"
        code << "#{prefix}    end\n"
        code << "#{prefix}    __col__ = (#{idx_var} % #{cols_var}) + 1\n"
        code << "#{prefix}    _O << \"<td class=\\\"col\#{__col__}\\\">\"\n"

        # Body content
        code << body_code

        code << "#{prefix}  end\n"  # end each_with_index

        # Close final tags
        code << "#{prefix}if !#{coll_var}.empty?\n"
        code << "#{prefix}  _O << \"</td>\"\n"
        code << "#{prefix}  _O << \"</tr>\\n\"\n"
        code << "#{prefix}end\n"
        code << "#{prefix}_S.pop_scope\n"

        @loop_depth -= 1
        code
      end

    end
  end
end
