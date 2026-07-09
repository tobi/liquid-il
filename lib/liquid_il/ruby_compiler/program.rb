# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Structural serializer for compiler-owned statement lines. Semantic facts
    # (types, effects, bindings) are already CodeFragment metadata; this layer
    # only coalesces adjacent output-append statements to keep the ISeq small.
    module ProgramSerialization
      # Compact generated source before compiling it: strip indentation, drop
      # comment-only lines, and fuse all statements onto one line. Whitespace
      # and comments never reach the ISeq, but per-line metadata in nested
      # ISeqs costs ~5% of the artifact, and RubyVM compile time scales with
      # source bytes. The pretty source is kept on the template for
      # to_ruby/write_ruby/inspection; only the compiled form is compact.
      # Emitted code is one complete statement per line with no heredocs or
      # continuation lines, so newline → ";" is semantics-preserving; the
      # frozen_string_literal magic comment must stay on its own line.
      # Consecutive output appends that survive IL-level merging (they meet
      # only after partial inlining assembles the final text) are fused:
      #   - raw + raw via string literal juxtaposition — `_O << "a" "b"` folds
      #     into a single literal at parse time (one putstring)
      #   - raw/expr runs via `<<` chaining — `_O << "a" << (x.to_s)` keeps one
      #     statement (one getlocal/pop) instead of one per append
      # Only self-contained right-hand sides chain: string literals, bare
      # identifiers, or fully parenthesized expressions.
      APPEND_LINE = /\A_O << ("(?:[^"\\]|\\.)*"|\w+|\(.*\))( unless _S\.has_interrupt\?)?\z/

      def compact_source(src)
        # UTF-8 explicitly: String.new defaults to BINARY, and the buffer's
        # encoding becomes the compiled file's — every string literal in the
        # template would otherwise be ASCII-8BIT (breaks encoding-sensitive
        # filters like unicode normalization in handleize).
        out = String.new(capacity: src.bytesize, encoding: Encoding::UTF_8)
        parts = nil   # chained append parts; last-literal juxtaposition applies
        guard = nil
        flush = lambda do
          if parts
            out << "_O << " << parts.join(" << ") << (guard || "") << ";"
            parts = nil
          end
        end
        src.each_line do |line|
          s = line.strip
          next if s.empty?
          if s.start_with?("#")
            out << s << "\n" if out.empty? && s.start_with?("# frozen_string_literal")
            next
          end
          if s.start_with?("_O << ") && (m = APPEND_LINE.match(s)) && (rhs = m[1]) && (rhs[0] != "(" || balanced_expr?(rhs))
            flush.call if parts && guard != m[2]
            if parts
              if rhs[0] == "\"" && parts[-1][-1] == "\""
                parts[-1] = parts[-1] + " " + rhs
              else
                parts << rhs
              end
            else
              parts = [rhs]
              guard = m[2]
            end
          else
            flush.call
            out << s << ";"
          end
        end
        flush.call
        out
      end

      # True when the string is one parenthesized expression — the closing
      # paren of the leading "(" is the final character. Skips string literals
      # so parens/quotes inside them don't confuse the depth scan.
      def balanced_expr?(s)
        depth = 0
        in_str = false
        i = 0
        len = s.length
        while i < len
          c = s.getbyte(i)
          if in_str
            if c == 0x5C # backslash
              i += 1
            elsif c == 0x22 # "
              in_str = false
            end
          else
            case c
            when 0x22 then in_str = true
            when 0x28 then depth += 1
            when 0x29
              depth -= 1
              return i == len - 1 if depth.zero?
            end
          end
          i += 1
        end
        false
      end

    end
  end
end
