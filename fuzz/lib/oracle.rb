# frozen_string_literal: true

module Fuzz
  # Comparison oracle (goal 02 doc, "The hardest part #2: noise control").
  # A naive `==` on rendered output drowns in known, legitimate differences.
  # This is a small pipeline of normalizers + an explicit, COUNTED
  # suppression-rule list -- every rule that fires increments a named
  # counter the runner prints every run, so noise is visible and auditable
  # rather than silently swallowed. Anything not covered by a named rule is
  # a finding.
  #
  # Verdict#status is one of:
  #   :match      -- both engines agree (directly, or via a suppression rule)
  #   :hang       -- either engine exceeded the per-case render timeout
  #                  (its own finding bucket -- see fuzz/lib/finding.rb)
  #   :finding    -- a real, uncategorized divergence
  Verdict = Struct.new(:status, :rule, :detail, keyword_init: true)

  module Oracle
    def self.compare(ref, lil)
      return Verdict.new(status: :hang, rule: :reference_hang, detail: nil) if ref[:hang]
      return Verdict.new(status: :hang, rule: :liquidil_hang, detail: nil) if lil[:hang]

      # Rule: parse errors are compared as a boolean ("did both engines
      # reject this template?"), never by message text -- reference's
      # syntax-error messages are not something LiquidIL's parser is trying
      # to byte-match, only whether a given input is syntactically valid
      # (goal 02 doc, "Known legitimate difference classes" #1).
      if ref[:syntax_error] || lil[:syntax_error]
        if ref[:syntax_error] && lil[:syntax_error]
          if ref[:message] == lil[:message]
            return Verdict.new(status: :match, rule: nil, detail: nil)
          end

          return Verdict.new(status: :match, rule: :parse_error_message_format, detail: nil)
        end
        return Verdict.new(status: :finding, rule: :parse_disagreement,
          detail: "reference syntax_error=#{!!ref[:syntax_error]} liquidil syntax_error=#{!!lil[:syntax_error]}")
      end

      # Neither is a syntax error. Both raised some other (non-syntax,
      # non-hang) exception -- a crash bucket, compared by class only
      # (message text for runtime StandardErrors is not something we pin).
      if !ref[:ok] && !lil[:ok]
        return ref[:error_class] == lil[:error_class] ? Verdict.new(status: :match) : Verdict.new(status: :finding, rule: :runtime_error_mismatch, detail: "ref=#{ref[:error_class]} lil=#{lil[:error_class]}")
      end

      if ref[:ok] != lil[:ok]
        return Verdict.new(status: :finding, rule: :ok_mismatch,
          detail: "ref ok=#{ref[:ok]} (#{ref[:error_class]}) lil ok=#{lil[:ok]} (#{lil[:error_class]})")
      end

      # Both ok: true. Compare rendered output byte-for-byte. No
      # normalization here on purpose -- numeric formatting (1.0 vs 1) and
      # hash iteration order have both been real bugs historically (goal 02
      # doc, difference classes #3/#4); suppressing them would hide exactly
      # the class of bug this tool exists to find.
      return Verdict.new(status: :match) if ref[:output] == lil[:output]

      Verdict.new(status: :finding, rule: :output_mismatch, detail: first_diff_context(ref[:output], lil[:output]))
    end

    def self.first_diff_context(a, b)
      a = a.to_s
      b = b.to_s
      i = 0
      i += 1 while i < a.size && i < b.size && a[i] == b[i]
      { index: i, ref_ctx: a[[i - 12, 0].max...(i + 12)], lil_ctx: b[[i - 12, 0].max...(i + 12)] }
    end
  end
end
