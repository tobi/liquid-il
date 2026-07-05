# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # ── IL statement-run dedup ──────────────────────────────────────────────
    #
    # Real templates carry TEMPLATE-AUTHORED repetition: the same little run of
    # statements copy-pasted with different inputs and assign targets. The
    # canonical example is order_email's "money" pattern
    #
    #   {% assign d = x | divided_by: 100 %}{% assign c = x | modulo: 100 %}
    #   ${{ d }}.{% if c < 10 %}0{% endif %}{{ c }}
    #
    # which appears 8× (subtotal / discount / shipping / tax / total / per line
    # item …), each compiling to ~250B of ISeq. This pass finds repeated runs of
    # consecutive statements, abstracts their differing operands into parameters,
    # emits ONE artifact-local lambda per repeated run (`_sqN__`), and replaces
    # every occurrence with a `[:CALL_SEQ, id, args]` opcode. Saving per group ≈
    # (occurrences − 1) × run_bytes − occurrences × call_bytes − lambda_overhead.
    #
    # Everything here decides on the IL (`@instructions`); nothing scans emitted
    # Ruby. v1 scope: main template body, at top level or inside IF branches —
    # never inside loops (loop bodies interact with @loop_var_aliases and the
    # effects frame) and never templates that use break/continue (interrupt
    # guards would leak into lambda bodies).
    module StatementDedup
      # A parameter reference spliced into an abstracted sequence body in place
      # of a variable-name / assign-target operand. Recognized by scope_lookup
      # and the assign terminators in generate_expression_statement.
      #   kind :input  → a value passed by the call site; reads emit _sqp{slot}__
      #   kind :local  → an assign target read back inside the run; reads emit
      #                  the dual local _sqv{slot}__
      #   kind :target → an assign target; the assign emits _H.af/_H.aff with the
      #                  parameter NAME string _sqp{slot}__ (and, when dual, also
      #                  writes _sqv{slot}__)
      SeqRef = Struct.new(:kind, :slot, :dual)

      # Opcodes permitted inside a dedup run. Conservative by design; see the
      # goal doc for why each excluded family is unsafe (interrupts, loops,
      # captures, cycles, counters, partials, dynamic/self reads, temps, jumps).
      DEDUP_ALLOWLIST = [
        IL::WRITE_RAW, IL::WRITE_VALUE, IL::WRITE_VAR, IL::WRITE_VAR_PATH,
        IL::CONST_NIL, IL::CONST_TRUE, IL::CONST_FALSE, IL::CONST_INT,
        IL::CONST_FLOAT, IL::CONST_STRING, IL::CONST_RANGE, IL::CONST_EMPTY,
        IL::CONST_BLANK, IL::FIND_VAR, IL::FIND_VAR_PATH, IL::LOOKUP_CONST_KEY,
        IL::LOOKUP_CONST_PATH, IL::LOOKUP_COMMAND, IL::CALL_FILTER, IL::COMPARE,
        IL::CASE_COMPARE, IL::CONTAINS, IL::BOOL_NOT, IL::BOOL_AND, IL::BOOL_OR,
        IL::IS_TRUTHY, IL::ASSIGN, IL::ASSIGN_LOCAL, IL::IF, IL::ELSE,
        IL::END_IF, IL::DUP, IL::POP, IL::BUILD_HASH, IL::NEW_RANGE
      ].to_h { |op| [op, true] }.freeze

      # A statement (at relative IF-depth 0) ends immediately after one of these.
      STATEMENT_END_OPS = [
        IL::WRITE_VALUE, IL::WRITE_RAW, IL::WRITE_VAR, IL::WRITE_VAR_PATH,
        IL::ASSIGN, IL::ASSIGN_LOCAL
      ].to_h { |op| [op, true] }.freeze

      MIN_OCCURRENCES = 3
      MIN_INSTRUCTIONS = 5
      MAX_PARAMS = 4

      # Byte-cost model for the savings gate, in ARTIFACT (ISeq binary) bytes.
      # CALIBRATED empirically: synthetic templates repeating the two canonical
      # runs (the money output-core: 10 instr / 2 value params; the assign
      # prefix: 8 instr / 1 value + 2 name params) compiled with LIQUID_DEDUP on
      # vs off across occurrence counts 2..8, diffing Artifact.encode.bytesize.
      # Fitted (ISeq bytes):
      #   inline run  ≈ 45–48 × instruction_count           → RUN_BYTES_PER_INSTR
      #   one CALL_SEQ site ≈ 100 + 110×value_args + 20×name_args
      #   lambda signature/closing overhead ≈ 40
      # The fit predicts the observed sign flip precisely: money-core dedup
      # regresses ~+52B at 3 occurrences and wins ~−72B at 4 (see report table).
      # Deliberately conservative (RUN_BYTES_PER_INSTR rounded down, filter-heavy
      # runs undercounted) so a marginal group errs toward NOT deduping.
      EST_RUN_BYTES_PER_INSTR = 45
      EST_CALL_BASE = 100
      EST_CALL_PER_VALUE_ARG = 110
      EST_CALL_PER_NAME_ARG = 20
      EST_LAMBDA_OVERHEAD = 40

      # Estimated artifact-byte saving of deduping `occ` occurrences of an
      # `instr_count`-instruction run with the given per-slot kinds. The lambda
      # body replaces one inline copy, hence (occ − 1) × run_bytes.
      def estimate_saving(occ, instr_count, slot_kinds)
        value_args = slot_kinds.count(:input)
        name_args = slot_kinds.count(:target)
        run_bytes = EST_RUN_BYTES_PER_INSTR * instr_count
        call_bytes = EST_CALL_BASE + EST_CALL_PER_VALUE_ARG * value_args +
                     EST_CALL_PER_NAME_ARG * name_args
        (occ - 1) * run_bytes - occ * call_bytes - EST_LAMBDA_OVERHEAD
      end

      def dedup_enabled?
        # OFF BY DEFAULT (2026-07-05): the pass's candidate matching costs
        # ~8x compile time on real templates (storefront set 9.6ms → 75ms;
        # order_email alone +48ms) for artifact wins worth single-digit
        # microseconds of remote-hit — a bad trade for the cache-miss
        # column. LIQUID_DEDUP=1 re-enables for development until the
        # matcher is made linear; the correctness tests run with it set.
        @optimize && ENV["LIQUID_DEDUP"] == "1"
      end

      # Entry point — called from generate_ruby BEFORE compute_hoisted_lookups.
      # Rewrites @instructions in place and registers sequences in @sequences.
      def dedup_statement_runs
        return unless dedup_enabled?
        # Templates with break/continue: PUSH_INTERRUPT is not in the allowlist,
        # but a run could still sit after a top-level interrupt; @uses_interrupts
        # also makes emitted writes carry `unless _S.has_interrupt?` guards we do
        # not want to reproduce inside a lambda. Skip wholesale — cheap and safe.
        return if @uses_interrupts

        groups = find_dedup_groups
        return if groups.empty?

        len = @instructions.length
        claimed = Array.new(len, false)
        replacements = [] # [start, end_exclusive, call_seq_inst]

        # Greedy: highest estimated saving first. Enumeration produces every
        # contiguous-statement window, so a group's occurrences can overlap each
        # other (sliding windows over "ABAB…") as well as ranges already claimed
        # by an earlier group. Pick a left-to-right MUTUALLY non-overlapping
        # subset before committing.
        groups.sort_by! { |g| -g[:saving] }
        groups.each do |g|
          picked = []
          last_end = -1
          g[:occurrences].sort_by { |o| o[:start] }.each do |o|
            next if o[:start] < last_end
            next if (o[:start]...o[:end]).any? { |i| claimed[i] }
            picked << o
            last_end = o[:end]
          end
          next if picked.size < MIN_OCCURRENCES
          # The surviving count can be below the point where dedup still pays —
          # re-check the saving at that count.
          next if estimate_saving(picked.size, g[:instr_count], g[:slot_kinds]) <= 0

          seq_id = @sequences.length
          seq = build_sequence(seq_id, g, picked.first)
          next unless seq
          @sequences << seq

          picked.each do |o|
            (o[:start]...o[:end]).each { |i| claimed[i] = true }
            replacements << [o[:start], o[:end], [IL::CALL_SEQ, seq_id, o[:args]]]
          end
        end

        return if replacements.empty?
        apply_replacements(replacements)
      end

      private

      # ── Candidate discovery ────────────────────────────────────────────────

      def find_dedup_groups
        blocks = []
        each_eligible_region { |lo, hi| collect_blocks(lo, hi, blocks) }

        # Enumerate every contiguous-statement window in every block, key by
        # abstracted shape, and group.
        by_key = Hash.new { |h, k| h[k] = [] }
        blocks.each do |stmts|
          n = stmts.length
          i = 0
          while i < n
            j = i
            while j < n
              info = analyze_window(stmts[i][0], stmts[j][1])
              by_key[info[:key]] << info if info
              j += 1
            end
            i += 1
          end
        end

        groups = []
        by_key.each_value do |windows|
          next if windows.length < MIN_OCCURRENCES
          first = windows.first
          instr_count = first[:instr_count]
          next if instr_count < MIN_INSTRUCTIONS
          occ = windows.length
          saving = estimate_saving(occ, instr_count, first[:slot_kinds])
          next if saving <= 0
          groups << {
            saving: saving,
            instr_count: instr_count,
            slot_kinds: first[:slot_kinds],
            dual_slots: first[:dual_slots],
            occurrences: windows.map { |w| { start: w[:start], end: w[:end], args: w[:args] } }
          }
        end
        groups
      end

      # Yield [lo, hi) for each maximal run of allowlisted instructions that sits
      # at loop depth 0. v1 scope is the main body OUTSIDE loops: loop bodies
      # interact with @loop_var_aliases and the effects frame, and a per-iteration
      # lambda call is real render cost. FOR_INIT/TABLEROW_INIT are already
      # barriers (off the allowlist); the depth counter additionally skips the
      # whole loop body between them.
      def each_eligible_region
        len = @instructions.length
        depth = 0
        i = 0
        while i < len
          op = @instructions[i][0]
          case op
          when IL::FOR_INIT, IL::TABLEROW_INIT
            depth += 1
            i += 1
            next
          when IL::FOR_END, IL::TABLEROW_END
            depth -= 1
            i += 1
            next
          end
          unless depth.zero? && DEDUP_ALLOWLIST[op]
            i += 1
            next
          end
          lo = i
          i += 1 while i < len && DEDUP_ALLOWLIST[@instructions[i][0]]
          yield lo, i
        end
      end

      # Segment [lo, hi) into statements at relative IF-depth 0 and recurse into
      # IF branches, appending each block's statement list to out_blocks.
      # A block is a flat list of [start, end_exclusive] statement ranges.
      def collect_blocks(lo, hi, out_blocks)
        stmts = []
        i = lo
        while i < hi
          start = i
          depth = 0
          closed = true
          loop do
            if i >= hi
              closed = false
              break
            end
            op = @instructions[i][0]
            if op == IL::IF
              depth += 1
              i += 1
            elsif op == IL::END_IF
              if depth.zero?
                closed = false
                break
              end
              depth -= 1
              i += 1
              break if depth.zero?
            elsif op == IL::ELSE && depth.zero?
              closed = false
              break
            elsif depth.zero? && STATEMENT_END_OPS[op]
              i += 1
              break
            else
              i += 1
            end
          end
          if closed && i > start
            stmts << [start, i]
          else
            break
          end
        end

        out_blocks << stmts unless stmts.empty?

        # Recurse into the branches of each conditional statement.
        stmts.each do |(s, e)|
          if_idx = find_if_marker(s, e)
          next unless if_idx
          else_idx, end_idx = if_branch_bounds(if_idx, e)
          next unless end_idx
          then_hi = else_idx || end_idx
          collect_blocks(if_idx + 1, then_hi, out_blocks) if then_hi > if_idx + 1
          collect_blocks(else_idx + 1, end_idx, out_blocks) if else_idx && end_idx > else_idx + 1
        end
      end

      # First IF marker at relative depth 0 within [s, e).
      def find_if_marker(s, e)
        depth = 0
        i = s
        while i < e
          op = @instructions[i][0]
          if op == IL::IF
            return i if depth.zero?
            depth += 1
          elsif op == IL::END_IF
            depth -= 1
          end
          i += 1
        end
        nil
      end

      # Given an IF marker index, return [else_idx_or_nil, end_idx_or_nil] for
      # its depth-matched ELSE and END_IF within the bound e.
      def if_branch_bounds(if_idx, e)
        depth = 0
        else_idx = nil
        i = if_idx + 1
        while i < e
          op = @instructions[i][0]
          case op
          when IL::IF then depth += 1
          when IL::ELSE then else_idx = i if depth.zero? && else_idx.nil?
          when IL::END_IF
            return [else_idx, i] if depth.zero?
            depth -= 1
          end
          i += 1
        end
        [else_idx, nil]
      end

      # ── Window abstraction ─────────────────────────────────────────────────

      # Analyze the instruction span [start, stop) as a candidate run. Returns
      # nil when it can't be abstracted (bad opcode, unbalanced IF, path read of
      # an in-run local, too many params). Otherwise returns a hash with a shape
      # key (occurrence-independent), per-slot kinds, dual-target slots, the
      # concrete per-occurrence call args, and the abstracted body.
      def analyze_window(start, stop)
        tokens = []
        slot_kinds = []          # slot index -> :input | :target
        input_slot_of = {}       # read-key -> slot
        target_slot_of = {}      # name -> slot
        dual_slots = {}          # target slot -> true (read back in-run)
        args = []                # slot -> [:input,name,path] | [:name,str]
        abstract = []
        depth = 0

        i = start
        while i < stop
          inst = @instructions[i]
          op = inst[0]
          return nil unless DEDUP_ALLOWLIST[op]

          case op
          when IL::IF then depth += 1
          when IL::END_IF then depth -= 1
          end
          return nil if depth.negative?

          case op
          when IL::FIND_VAR, IL::WRITE_VAR
            ref, tok = ref_for_read(inst[1], [], input_slot_of, target_slot_of,
                                    slot_kinds, dual_slots, args)
            return nil unless ref
            abstract << [op, ref]
            tokens << "#{op}:#{tok}"
          when IL::FIND_VAR_PATH, IL::WRITE_VAR_PATH
            name = inst[1]
            # An in-run local read WITH a path (local.foo) would need a runtime
            # lookup on the dual local — out of v1 scope. Bail.
            return nil if target_slot_of.key?(name)
            ref, tok = ref_for_read(name, inst[2], input_slot_of, target_slot_of,
                                    slot_kinds, dual_slots, args)
            return nil unless ref
            # Collapse the whole pathed read into a single value parameter, so
            # FIND_VAR_PATH → FIND_VAR(param), WRITE_VAR_PATH → WRITE_VAR(param).
            out_op = op == IL::WRITE_VAR_PATH ? IL::WRITE_VAR : IL::FIND_VAR
            abstract << [out_op, ref]
            tokens << "#{op}:#{tok}"
          when IL::ASSIGN, IL::ASSIGN_LOCAL
            name = inst[1]
            slot = target_slot_of[name]
            unless slot
              slot = slot_kinds.length
              slot_kinds << :target
              target_slot_of[name] = slot
              args[slot] = [:name, name]
            end
            abstract << [op, SeqRef.new(:target, slot, false)]
            tokens << "#{op}:T#{slot}"
          when IL::CALL_FILTER
            # name + argc fixed; LINE ignored (occurrences differ only by source
            # line — the abstracted body bakes the first occurrence's line).
            abstract << inst
            tokens << "CF:#{inst[1]}:#{inst[2]}"
          when IL::CONST_STRING, IL::WRITE_RAW
            abstract << inst
            # inspect keeps the key ASCII-safe: a folded base64 result carries
            # BINARY encoding and joining it raw against UTF-8 tokens raises.
            tokens << "#{op}:#{inst[1].inspect}"
          else
            abstract << inst
            tokens << "#{op}:#{inst[1..].inspect}"
          end

          return nil if slot_kinds.length > MAX_PARAMS
          i += 1
        end
        return nil unless depth.zero?

        if dual_slots.any?
          abstract.each do |ai|
            r = ai[1]
            r.dual = true if r.is_a?(SeqRef) && r.kind == :target && dual_slots[r.slot]
          end
        end

        {
          key: tokens.join("\n"),
          start: start,
          end: stop,
          instr_count: stop - start,
          slot_kinds: slot_kinds,
          dual_slots: dual_slots,
          args: args,
          abstract: abstract
        }
      end

      # Resolve a variable READ to a SeqRef + shape token. An in-run assign
      # target read (path empty, enforced by caller) becomes a :local dual
      # reference; anything else is a by-value :input parameter keyed on the
      # concrete (name,path) so repeats within one run share a slot.
      def ref_for_read(name, path, input_slot_of, target_slot_of, slot_kinds, dual_slots, args)
        if (tslot = target_slot_of[name])
          dual_slots[tslot] = true
          [SeqRef.new(:local, tslot, true), "L#{tslot}"]
        else
          # Structural key ([name, path]) so distinct reads never collide the
          # way a string join could ("order"+["a","b"] vs "order"+["ab"]).
          key = [name, path]
          slot = input_slot_of[key]
          unless slot
            slot = slot_kinds.length
            slot_kinds << :input
            input_slot_of[key] = slot
            args[slot] = [:input, name, path]
          end
          [SeqRef.new(:input, slot, false), "I#{slot}"]
        end
      end

      # ── Sequence body compilation ──────────────────────────────────────────

      # Build a registered sequence from a representative window. Compiles the
      # abstracted body once (capturing its effects) via the normal codegen.
      def build_sequence(seq_id, group, occ)
        info = analyze_window(occ[:start], occ[:end])
        return nil unless info
        abstract = info[:abstract] + [IL::I_HALT]

        param_count = group[:slot_kinds].length
        param_locals = (0...param_count).map { |k| "_sqp#{k}__" }

        body, effects = compile_sequence_body(abstract)
        return nil if body.nil?

        {
          id: seq_id,
          name: "_sq#{seq_id}__",
          param_locals: param_locals,
          dual_slots: group[:dual_slots].keys,
          body: body,
          effects: effects
        }
      end

      # Compile an abstracted instruction array to a lambda body using the same
      # generate_statement / build_expression machinery, capturing the body's
      # scope effects WITHOUT folding them into the caller frame (they are
      # merged per CALL_SEQ site instead).
      def compile_sequence_body(abstract)
        saved_insts = @instructions
        saved_pc = @pc
        saved_effects = @effects
        saved_aliases = @loop_var_aliases
        saved_interrupts = @uses_interrupts

        @instructions = abstract
        @pc = 0
        @loop_var_aliases = {}
        @uses_interrupts = false
        @effects = [Effects.new] # throwaway parent to absorb the pop merge
        push_effects

        code = String.new
        while @pc < @instructions.length
          inst = @instructions[@pc]
          break if inst.nil? || inst[0] == IL::HALT
          result = generate_statement(2)
          if result.nil?
            code = nil
            break
          end
          code << result
        end
        effects = pop_effects

        @instructions = saved_insts
        @pc = saved_pc
        @effects = saved_effects
        @loop_var_aliases = saved_aliases
        @uses_interrupts = saved_interrupts
        [code, effects]
      end

      # ── Rewrite @instructions, remapping absolute jump targets ─────────────

      def apply_replacements(replacements)
        replacements.sort_by! { |r| r[0] }
        len = @instructions.length
        # old index -> new index; interior indices of a removed run map to the
        # CALL_SEQ position (defensive — jumps never target run interiors).
        new_index = Array.new(len + 1, 0)
        result = []
        cursor = 0
        r = 0
        old = 0
        while old < len
          if r < replacements.length && old == replacements[r][0]
            rep_start, rep_end, call_inst = replacements[r]
            (rep_start...rep_end).each { |k| new_index[k] = cursor }
            result << call_inst
            cursor += 1
            old = rep_end
            r += 1
          else
            new_index[old] = cursor
            result << @instructions[old]
            cursor += 1
            old += 1
          end
        end
        new_index[len] = cursor

        # Remap absolute jump / loop targets (strip_labels already ran, so
        # these are absolute instruction indices).
        result.each do |inst|
          case inst[0]
          when IL::JUMP, IL::JUMP_IF_EMPTY, IL::JUMP_IF_INTERRUPT
            inst[1] = new_index[inst[1]] if inst[1].is_a?(Integer) && inst[1] <= len
          when IL::FOR_NEXT, IL::TABLEROW_NEXT
            inst[1] = new_index[inst[1]] if inst[1].is_a?(Integer) && inst[1] <= len
            inst[2] = new_index[inst[2]] if inst[2].is_a?(Integer) && inst[2] <= len
          end
        end

        @instructions.replace(result)
      end
    end
  end
end
