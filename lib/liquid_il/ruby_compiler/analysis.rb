# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Pre-emission lookup analysis plus structured scope-effect tracking shared
    # by loop, partial, expression, and statement emitters.
    module AnalysisEmitter
      private

      # ── Hoisted scope lookups ───────────────────────────────────
      # A variable read HOIST_MIN_USES+ times whose name is never written
      # anywhere in the template reads the same value every time — bind it
      # to a local once (saves a send + operands per site in the ISeq, and
      # the repeated scope lookups at render). Decided entirely on the IL
      # before codegen; emission consults @hoisted_lookups via scope_lookup.
      # Bails when the template can mutate arbitrary caller scope: include
      # partials (static or dynamic), sections, or any opcode not in the
      # neutral table (future/custom tag IL stays conservative by default).
      HOIST_MIN_USES = 3
      EMPTY_HOISTS = {}.freeze

      # Ops that neither read nor write template variable names.
      HOIST_NEUTRAL_OPS = [
        IL::WRITE_RAW, IL::WRITE_VALUE, IL::CONST_NIL, IL::CONST_TRUE,
        IL::CONST_FALSE, IL::CONST_INT, IL::CONST_FLOAT, IL::CONST_STRING,
        IL::CONST_RANGE, IL::CONST_EMPTY, IL::CONST_BLANK, IL::FIND_VAR_DYNAMIC,
        IL::FIND_SELF, IL::LOOKUP_KEY, IL::LOOKUP_CONST_KEY, IL::LOOKUP_CONST_PATH,
        IL::LOOKUP_COMMAND, IL::PUSH_CAPTURE, IL::POP_CAPTURE, IL::LABEL,
        IL::JUMP, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT, IL::HALT,
        IL::COMPARE, IL::CASE_COMPARE, IL::CONTAINS, IL::BOOL_NOT, IL::IS_TRUTHY,
        IL::BOOL_AND, IL::BOOL_OR, IL::IF, IL::ELSE, IL::END_IF, IL::PUSH_SCOPE,
        IL::POP_SCOPE, IL::NEW_RANGE, IL::CALL_FILTER, IL::FOR_NEXT, IL::FOR_END,
        IL::PUSH_FORLOOP, IL::POP_FORLOOP, IL::PUSH_INTERRUPT, IL::POP_INTERRUPT,
        IL::CYCLE_STEP, IL::CYCLE_STEP_VAR, IL::RENDER_PARTIAL, IL::CONST_RENDER,
        IL::TABLEROW_NEXT, IL::TABLEROW_END, IL::DUP, IL::POP, IL::BUILD_HASH,
        IL::STORE_TEMP, IL::LOAD_TEMP, IL::IFCHANGED_CHECK, IL::NOOP,
        :PAGINATE_TEARDOWN
      ].to_h { |op| [op, true] }.freeze

      # Fallback census for when the optimizer did not hand one in via @hoist_data
      # (label-free templates that skip link_and_strip, or optimize: false). The
      # normal path folds this exact walk into link_and_strip's final-stream scan
      # — see Compiler#link_and_strip.
      def compute_hoisted_lookups
        counts = Hash.new(0)
        written = nil
        @instructions.each do |inst|
          op = inst[0]
          case op
          when IL::FIND_VAR, IL::FIND_VAR_PATH, IL::WRITE_VAR, IL::WRITE_VAR_PATH
            counts[inst[1]] += 1
          when IL::ASSIGN, IL::ASSIGN_LOCAL, IL::INCREMENT, IL::DECREMENT,
               IL::FOR_INIT, IL::TABLEROW_INIT
            (written ||= {})[inst[1]] = true
          when IL::CALL_SEQ
            # A deduped run's args: :input reads its base name; :name writes an
            # assign-target name. Kind-2 target names are dynamic inside the body,
            # so conservatively mark every passed name as written.
            inst[2].each do |arg|
              if arg[0] == :input
                counts[arg[1]] += 1
              else
                (written ||= {})[arg[1]] = true
              end
            end
          when :PAGINATE_SETUP
            w = (written ||= {})
            w["paginate"] = true
            parts = inst[1].to_s.split(".")
            w[parts.first] = true
            w[parts.last] = true
          when IL::INCLUDE_PARTIAL, IL::CONST_INCLUDE, :SHOPIFY_SECTION_RENDER
            return EMPTY_HOISTS
          else
            return EMPTY_HOISTS unless HOIST_NEUTRAL_OPS[op]
          end
        end
        derive_hoisted_lookups(counts, written, false)
      end

      # Turn a read census (name -> count), a written-name set, and a blocked flag
      # into the name -> local map. Shared by the fallback scan above and the
      # optimizer-provided census (@hoist_data).
      def derive_hoisted_lookups(counts, written, blocked)
        return EMPTY_HOISTS if blocked
        hoisted = nil
        counts.each do |name, c|
          next if c < HOIST_MIN_USES
          next if written&.key?(name)
          next if name == "forloop" || name == "tablerowloop"
          hoisted ||= {}
          hoisted[name] = "_lk#{hoisted.size}__"
        end
        hoisted || EMPTY_HOISTS
      end

      # ── Emission metadata / effects frames ─────────────────────

      def require_codegen_helper(name)
        @required_helpers.add(name)
      end

      def require_filter_cache(name)
        @required_filter_caches.add(name)
      end

      # Effects frames carry scope semantics for nested loop/partial planning;
      # CodeFragment carries expression semantics. Together they replace source
      # inspection with facts recorded at the point where code is emitted.
      # One frame per loop body being generated. Emitters record scope
      # effects at the moment they emit — which names the body reads through
      # the scope, whether it calls a scope-reading (non-isolated) partial,
      # whether it performs dynamic/whole-scope reads. generate_for then
      # decides needs_scope_sync/needs_forloop from the frame instead of
      # substring-matching its own generated text, so emission shapes and
      # the sync decision can never drift apart. Isolated {% render %} calls
      # don't set any flag: they cannot see caller locals, and their arg
      # expressions record their own reads — loops containing only those
      # stay on the plain ei/eif fast path.
      Effects = Struct.new(:reads, :dynamic, :open_call, :uses_forloop, :uses_parentloop)

      def push_effects
        @effects << Effects.new
      end

      # Pop the loop's frame and fold it into the parent: scope reads and
      # call/dynamic flags propagate (a grandchild's scope read can require
      # the outer loop to sync); uses_forloop does not (it binds to the
      # popped loop's own drop). uses_parentloop propagates conservatively:
      # a chained forloop.parentloop.parentloop needs every enclosing drop
      # to carry its parent.
      def pop_effects
        child = @effects.pop
        parent = @effects.last
        if parent
          parent.dynamic ||= child.dynamic
          parent.open_call ||= child.open_call
          parent.uses_parentloop ||= child.uses_parentloop
          if child.reads
            (parent.reads ||= Set.new).merge(child.reads)
          end
        end
        child
      end

      def record_scope_read(name)
        f = @effects.last
        (f.reads ||= Set.new) << name if f
      end

      # Whole-scope or computed-name reads ({{ [var] }}, {{ self }},
      # tablerow internals): the enclosing loop must publish its bindings.
      def record_dynamic_read
        f = @effects.last
        f.dynamic = true if f
      end

      # Partial invocations that read the caller scope at render time
      # (include, dynamic include, sections).
      def record_open_partial_call
        f = @effects.last
        f.open_call = true if f
      end

      # forloop.parentloop access (or the whole drop escaping — assigns,
      # filters, {{ forloop }}): the loop's drop must carry its parent.
      def record_parentloop_use
        f = @effects.last
        f.uses_parentloop = true if f
      end

      # The single emission primitive for whole-variable reads: loop-var
      # alias, hoisted local, or scope lookup. A whole-value read of the
      # forloop drop lets it escape (assign/filter/partial arg), so its
      # parentloop becomes reachable; pathed reads go through
      # scope_lookup_pathed, whose callers record parentloop use only when
      # the path actually touches it.
      def loop_item_binding?(name)
        @loop_var_aliases.key?(name) && name != "forloop" && name != "tablerowloop"
      end

      def scope_lookup(name)
        return seq_ref_local(name) if name.is_a?(StatementDedup::SeqRef)
        record_parentloop_use if name == "forloop"
        scope_lookup_pathed(name)
      end

      # Inside a deduped-sequence body a variable read is a parameter, not a scope
      # lookup: an :input value binds to _sqp{slot}__, an assign target read back
      # in the run binds to its dual local _sqv{slot}__.
      def seq_ref_local(ref)
        ref.kind == :local ? "_sqv#{ref.slot}__" : "_sqp#{ref.slot}__"
      end

      def scope_lookup_pathed(name)
        return seq_ref_local(name) if name.is_a?(StatementDedup::SeqRef)
        if (alias_var = @loop_var_aliases[name])
          @effects.last.uses_forloop = true if name == "forloop"
          alias_var
        elsif @scope_bindings && (binding = @scope_bindings[name])
          binding.source
        elsif (local = @hoisted_lookups[name])
          local
        else
          record_scope_read(name)
          "_S.lookup(#{name.inspect})"
        end
      end

    end
  end
end
