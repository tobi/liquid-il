# frozen_string_literal: true

require "strscan"

module LiquidIL
  # High-performance template tokenizer
  # Stage 1: Splits template into RAW, TAG, and VAR tokens
  #
  # Zero-allocation design (following tenderlove's StringScanner patterns):
  # - next_token returns only the token type symbol (no array/tuple)
  # - Position offsets stored as ivars, not in allocated arrays
  # - Content extracted lazily via token_content (byteslice on demand)
  # - Trim flags stored as ivars
  class TemplateLexer
    RAW = :RAW
    TAG = :TAG
    VAR = :VAR
    EOF = :EOF

    # Regex patterns - pre-compiled for performance
    TAG_END = /-?%\}/
    VAR_END = /-?\}\}/

    # Pattern to find endraw (with optional whitespace and trim)
    ENDRAW_PATTERN = /\{%-?\s*endraw\s*-?%\}/

    # Token state — read these instead of indexing into arrays
    attr_reader :token_type, :token_start, :token_end, :trim_left, :trim_right
    # Content region within the token (excludes delimiters, not yet stripped)
    attr_reader :content_start, :content_end

    def initialize(source)
      @source = source
      @source_bytes = source.bytesize
      @scanner = StringScanner.new(source)
      @trim_next = false
      # Token state
      @token_type = nil
      @token_start = 0
      @token_end = 0
      @trim_left = false
      @trim_right = false
      @content_start = 0
      @content_end = 0
      @tag_name_pos = -1
      @tag_name_cache = nil
    end

    def reset
      @scanner.pos = 0
      @trim_next = false
      @tag_name_pos = -1
      @tag_name_cache = nil
      @token_type = nil
    end

    # Extract token content as string — only call when you need the actual text.
    # For RAW tokens: the raw text (with trim applied if needed)
    # For TAG/VAR tokens: the markup between delimiters (stripped)
    def token_content
      s = @source.byteslice(@content_start, @content_end - @content_start)
      if @token_type == RAW
        # Apply trim from previous token
        @_needs_lstrip ? s.lstrip : s
      else
        s.strip
      end
    end

    # Extract just the tag name from a TAG token — no content string allocation.
    # Scans bytes from content_start, skips leading whitespace, extracts first word, downcases.
    # Returns a frozen string (no allocation for common tag names).
    COMMON_TAGS = %w[if elsif else endif unless endunless for endfor case when endcase
                     assign capture endcapture comment endcomment raw endraw render include
                     increment decrement tablerow endtablerow cycle ifchanged break continue
                     liquid echo].each_with_object({}) { |t, h| h[t] = t.freeze }.freeze

    def tag_name
      # Memoized per token: parse_block_body checks the name for end-tags and
      # parse_tag reads it again for dispatch — one scan instead of two.
      return @tag_name_cache if @tag_name_pos == @content_start

      @tag_name_pos = @content_start
      @tag_name_cache = compute_tag_name
    end

    def compute_tag_name
      src = @source
      pos = @content_start
      limit = @content_end

      # Skip leading whitespace
      while pos < limit
        b = src.getbyte(pos)
        break unless b == 32 || b == 9 || b == 10 || b == 13  # space, tab, newline, cr
        pos += 1
      end

      # Find end of tag name (first whitespace or end of content)
      name_start = pos
      while pos < limit
        b = src.getbyte(pos)
        break if b == 32 || b == 9 || b == 10 || b == 13
        pos += 1
      end

      return nil if pos == name_start

      # Extract and downcase the tag name
      # For common tags (all already lowercase), COMMON_TAGS lookup returns frozen string (no extra alloc)
      name = src.byteslice(name_start, pos - name_start)
      COMMON_TAGS[name] || name.downcase
    end

    # Scan raw content until {% endraw %}
    # Returns [content, trim_left, trim_right] or nil if no endraw found
    def scan_raw_body
      start_pos = @scanner.pos
      @trim_next = false

      if @scanner.skip_until(ENDRAW_PATTERN)
        match_len = @scanner.matched_size
        match_start = @scanner.pos - match_len
        content = @source.byteslice(start_pos, match_start - start_pos)

        matched = @scanner.matched
        trim_l = matched.include?("{%-")
        trim_r = matched.include?("-%}")
        @trim_next = trim_r

        [content, trim_l, trim_r]
      else
        nil
      end
    end

    # Advance to next token. Returns token type symbol.
    # Access token_start, token_end, trim_left, trim_right, token_content after.
    def next_token
      if @scanner.eos?
        @token_type = EOF
        @token_start = @scanner.pos
        @token_end = @scanner.pos
        @trim_left = false
        @trim_right = false
        return EOF
      end

      # Check first two bytes to see if we're at a Liquid delimiter
      pos = @scanner.pos
      b0 = @source.getbyte(pos)
      if b0 == 123  # '{'
        b1 = @source.getbyte(pos + 1)
        if b1 == 123 || b1 == 37  # '{' or '%'
          return scan_liquid_token
        end
      end

      scan_raw_token
    end

    private

    def scan_raw_token
      start_pos = @scanner.pos
      @_needs_lstrip = @trim_next
      @trim_next = false

      # Fast path: use String#byteindex (C implementation) to skip to '{'
      # positions instead of byte-by-byte scanning in Ruby.
      # MUST be byteindex, not index: all lexer positions are byte offsets
      # (getbyte/byteslice/StringScanner.pos), and char indexes diverge as
      # soon as the template contains a multibyte character.
      pos = @source_bytes  # Default: no delimiter found, raw to end
      src = @source
      search_from = start_pos
      while (brace_pos = src.byteindex("{", search_from))
        search_from = brace_pos + 1
        b1 = src.getbyte(brace_pos + 1)
        if b1 == 123 || b1 == 37  # '{' or '%'
          pos = brace_pos
          break
        end
      end

      @scanner.pos = pos

      @token_type = RAW
      @token_start = start_pos
      @token_end = pos
      @content_start = start_pos
      @content_end = pos
      @trim_left = false
      @trim_right = false
      RAW
    end

    def scan_liquid_token
      start_pos = @scanner.pos
      pos = start_pos
      src = @source

      # Read opening delimiter bytes: {{ or {%
      # b0 is '{', already confirmed
      b1 = src.getbyte(pos + 1)  # '{' or '%'
      pos += 2

      if b1 == 123  # {{ variable
        type = VAR
        # Check for trim: {{-
        if src.getbyte(pos) == 45  # '-'
          # But not {{-}} (special case: '-' is content, not trim)
          if src.getbyte(pos + 1) == 125 && src.getbyte(pos + 2) == 125  # '}}'
            # {{-}} : treat as {{ with trim_left, -}} as end
            @trim_left = true
          else
            pos += 1
            @trim_left = true
          end
        else
          @trim_left = false
        end
        end_pattern = VAR_END
      else  # {% tag
        type = TAG
        if src.getbyte(pos) == 45  # '-'
          # Check for {%--%} or {%-%} special cases
          next_b = src.getbyte(pos + 1)
          if next_b == 45 && src.getbyte(pos + 2) == 37 && src.getbyte(pos + 3) == 125
            # {%--%}
            @trim_left = true
          elsif next_b == 37 && src.getbyte(pos + 2) == 125
            # {%-%}
            @trim_left = true
          else
            pos += 1
            @trim_left = true
          end
        else
          @trim_left = false
        end
        end_pattern = TAG_END
      end

      content_start = pos

      # Liquid Ruby accepts compact comment delimiters like `{%comment}` and
      # `{%endcomment}` (without the `%` before `}`). Keep this quirk narrow so
      # general tag parsing still requires normal `%}` terminators.
      if type == TAG
        if src.byteslice(content_start, 8) == "comment}"
          @scanner.pos = content_start + 8
          @token_type = type
          @token_start = start_pos
          @token_end = @scanner.pos
          @content_start = content_start
          @content_end = content_start + 7
          @trim_right = false
          @trim_next = false
          return type
        elsif src.byteslice(content_start, 11) == "endcomment}"
          @scanner.pos = content_start + 11
          @token_type = type
          @token_start = start_pos
          @token_end = @scanner.pos
          @content_start = content_start
          @content_end = content_start + 10
          @trim_right = false
          @trim_next = false
          return type
        end
      end

      @scanner.pos = pos

      # Find matching end delimiter
      if @scanner.skip_until(end_pattern)
        match_len = @scanner.matched_size
        content_end_pos = @scanner.pos - match_len
        end_pos = @scanner.pos

        # Check trim_right: does the end delimiter start with '-'?
        # matched starts with '-' if trim
        @trim_right = @source.getbyte(content_end_pos) == 45  # '-'
        @trim_next = @trim_right

        @token_type = type
        @token_start = start_pos
        @token_end = end_pos
        @content_start = content_start
        @content_end = content_end_pos
        type
      else
        if type == VAR
          raise SyntaxError.new("Variable '{{' was not properly terminated with regexp: /\\}\\}/", position: start_pos, source: @source)
        else
          raise SyntaxError.new("Tag '{%' was not properly terminated with regexp: /%\\}/", position: start_pos, source: @source)
        end
      end
    end
  end

  # High-performance expression lexer
  # Stage 2: Tokenizes tag/variable markup
  #
  # Already follows zero-allocation patterns:
  # - Byte lookup tables for O(1) punctuation dispatch
  # - getbyte + pos manipulation instead of scan (no string allocation)
  # - byteslice only when consumer requests value
  # - Perfect hash for keyword identification (no .downcase allocation)
  class ExpressionLexer
    # Token types
    IDENTIFIER = :IDENTIFIER
    NUMBER = :NUMBER
    STRING = :STRING
    DOT = :DOT
    DOTDOT = :DOTDOT
    PIPE = :PIPE
    COLON = :COLON
    COMMA = :COMMA
    LPAREN = :LPAREN
    RPAREN = :RPAREN
    LBRACKET = :LBRACKET
    RBRACKET = :RBRACKET
    EQ = :EQ
    NE = :NE
    LT = :LT
    LE = :LE
    GT = :GT
    GE = :GE
    FAT_ARROW = :FAT_ARROW  # => (for lax parsing: foo=>bar = foo['bar'])
    CONTAINS = :CONTAINS
    AND = :AND
    OR = :OR
    EOF = :EOF

    # Literal keywords
    NIL = :NIL
    TRUE = :TRUE
    FALSE = :FALSE
    EMPTY = :EMPTY
    BLANK = :BLANK

    # Byte lookup table for single-char punctuation (indexed by ASCII code)
    PUNCT_TABLE = []
    PUNCT_TABLE[".".ord] = :DOT_OR_DOTDOT  # needs lookahead
    PUNCT_TABLE["|".ord] = PIPE
    PUNCT_TABLE[":".ord] = COLON
    PUNCT_TABLE[",".ord] = COMMA
    PUNCT_TABLE["(".ord] = LPAREN
    PUNCT_TABLE[")".ord] = RPAREN
    PUNCT_TABLE["[".ord] = LBRACKET
    PUNCT_TABLE["]".ord] = RBRACKET

    # Comparison operator first chars
    COMP_TABLE = []
    COMP_TABLE["=".ord] = :EQ_START
    COMP_TABLE["!".ord] = :NE_START
    COMP_TABLE["<".ord] = :LT_START
    COMP_TABLE[">".ord] = :GT_START

    # Keywords: nil null true false empty blank and or contains
    # (all lowercase, matched case-insensitively without .downcase allocation)
    # Disambiguated by length, then first byte:
    # len 2: "or" (only one)
    # len 3: "nil", "and" — disambiguate by 1st byte: 'n'=110 vs 'a'=97
    # len 4: "null", "true" — 1st byte: 'n'=110 vs 't'=116
    # len 5: "false", "empty", "blank" — 1st byte: 'f'=102, 'e'=101, 'b'=98 — all unique
    # len 8: "contains" (only one)

    # Byte-indexed lookup tables per length (indexed by first byte)
    KW_LEN2_TABLE = []
    KW_LEN2_TABLE["o".ord] = OR  # "or"

    KW_LEN3_TABLE = []
    KW_LEN3_TABLE["n".ord] = ["nil", NIL]
    KW_LEN3_TABLE["a".ord] = ["and", AND]

    KW_LEN4_TABLE = []
    KW_LEN4_TABLE["n".ord] = ["null", NIL]
    KW_LEN4_TABLE["t".ord] = ["true", TRUE]

    KW_LEN5_TABLE = []
    KW_LEN5_TABLE["f".ord] = ["false", FALSE]
    KW_LEN5_TABLE["e".ord] = ["empty", EMPTY]
    KW_LEN5_TABLE["b".ord] = ["blank", BLANK]

    CONTAINS_BYTES = "contains".bytes.freeze

    # Pre-compiled patterns
    WHITESPACE = /\s+/

    attr_accessor :error_mode

    def initialize(source = "", error_mode: :lax)
      @source = source
      @source_bytes = source.bytesize
      @scanner = StringScanner.new(source)
      @current_token = nil
      @current_value = nil
      @peeked = false
      @error_mode = error_mode
    end

    def reset_source(source)
      @source = source
      @source_bytes = source.bytesize
      @scanner.string = source
      @scanner.pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
      self
    end

    def reset
      @scanner.pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
    end

    # Save current lexer state for backtracking (single slot, no allocation).
    # Both call sites save+restore immediately with no overlap, so nested
    # saves are not supported.
    def save_state
      @saved_pos = @scanner.pos
      @saved_token = @current_token
      @saved_value = @current_value
      @saved_peeked = @peeked
    end

    # Restore lexer state from the last save_state
    def restore_state
      @scanner.pos = @saved_pos
      @current_token = @saved_token
      @current_value = @saved_value
      @peeked = @saved_peeked
    end

    # Get current token type (no allocation if already peeked)
    def current
      peek unless @peeked
      @current_token
    end

    # Get current token value (allocates string only when called)
    def value
      @current_value
    end

    # Look at next token without consuming
    def peek
      return @current_token if @peeked
      advance
      @peeked = true
      @current_token
    end

    # Consume current token and advance
    def advance
      @current_value = nil

      # Skip whitespace — inline byte check for common case (no whitespace)
      pos = @scanner.pos
      while (b = @source.getbyte(pos)) && (b == 32 || b == 9 || b == 10 || b == 13)
        pos += 1
      end
      # Combine EOS check + scanner.pos update + byte lookup in one step
      if pos >= @source_bytes
        @scanner.pos = pos
        @current_token = EOF
        @peeked = true
        return EOF
      end
      @scanner.pos = pos
      byte = @source.getbyte(pos)

      # Check punctuation table first (most common)
      if (punct = PUNCT_TABLE[byte])
        scan_punctuation(punct)
      elsif (comp = COMP_TABLE[byte])
        scan_comparison(comp)
      elsif byte == 39 || byte == 34  # ' or "
        scan_string(byte)
      elsif byte == 38  # & — not a valid Liquid operator
        # In lax mode, treat lone & or && as end of expression (trailing junk)
        # Liquid does not support && as an operator; it's parsed as 'and' keyword only
        @current_token = EOF
      elsif byte == 36 && @error_mode == :lax # $ junk in lax filter markup
        @scanner.pos += 1 while @source.getbyte(@scanner.pos) == 36
        @peeked = false
        return advance
      elsif byte >= 48 && byte <= 57 || byte == 45  # 0-9 or -
        scan_number
      else
        scan_identifier_or_keyword
      end

      @peeked = true
      @current_token
    end

    # Consume if current matches expected
    def accept(token_type)
      if current == token_type
        advance
        true
      else
        false
      end
    end

    # Require current to match, raise otherwise
    def expect(token_type)
      unless accept(token_type)
        raise SyntaxError, "Expected #{token_type} but got #{current} at position #{@scanner.pos}"
      end
    end

    def eos?
      current == EOF
    end

    private

    def scan_punctuation(punct)
      if punct == :DOT_OR_DOTDOT
        next_byte = @source.getbyte(@scanner.pos + 1)
        if next_byte == 46 # another . -> DOTDOT
          # Liquid laxly treats an extra dot in ranges, e.g. (1...5), as (1..5).
          # If the third dot is followed by a digit, consume it as range noise
          # instead of letting it start a leading-decimal number (.5).
          third_byte = @source.getbyte(@scanner.pos + 2)
          fourth_byte = @source.getbyte(@scanner.pos + 3)
          if third_byte == 46 && fourth_byte && fourth_byte >= 48 && fourth_byte <= 57
            @scanner.pos += 3
          else
            @scanner.pos += 2
          end
          @current_token = DOTDOT
        elsif next_byte && next_byte >= 48 && next_byte <= 57 # digit -> float like .5
          scan_leading_decimal_number
        else
          @scanner.pos += 1
          @current_token = DOT
        end
      elsif punct == PIPE && @source.getbyte(@scanner.pos + 1) == 124  # || — not a valid Liquid operator
        # In lax mode, treat || as end of expression (the first | starts a filter
        # but the second | is junk). Just emit the first | as PIPE and let the
        # parser handle the trailing junk.
        @scanner.pos += 1
        @current_token = PIPE
      else
        @scanner.pos += 1
        @current_token = punct
      end
    end

    # Scan number starting with decimal like .5
    def scan_leading_decimal_number
      start = @scanner.pos
      @scanner.pos += 1 # skip .
      # Consume digits
      while (byte = @source.getbyte(@scanner.pos)) && byte >= 48 && byte <= 57
        @scanner.pos += 1
      end
      @current_value = @source.byteslice(start, @scanner.pos - start)
      @current_token = NUMBER
    end

    def scan_comparison(comp)
      case comp
      when :EQ_START
        @scanner.pos += 1
        next_byte = @source.getbyte(@scanner.pos)
        if next_byte == 61  # =
          @scanner.pos += 1
          @current_token = EQ
        elsif next_byte == 62  # > (fat arrow for lax parsing)
          @scanner.pos += 1
          @current_token = FAT_ARROW
        else
          # Lax mode: lone '=' is not a valid operator, treat as end of expression
          @scanner.pos -= 1
          @current_token = EOF
        end
      when :NE_START
        @scanner.pos += 1
        if @source.getbyte(@scanner.pos) == 61  # =
          @scanner.pos += 1
          @current_token = NE
        else
          # Lax mode: lone '!' is not a valid operator, treat as end of expression
          @scanner.pos -= 1  # back up past the '!'
          @current_token = EOF
        end
      when :LT_START
        @scanner.pos += 1
        if @source.getbyte(@scanner.pos) == 61  # =
          @scanner.pos += 1
          @current_token = LE
        elsif @source.getbyte(@scanner.pos) == 62  # >
          @scanner.pos += 1
          @current_token = NE  # <> is also !=
        else
          @current_token = LT
        end
      when :GT_START
        @scanner.pos += 1
        if @source.getbyte(@scanner.pos) == 61  # =
          @scanner.pos += 1
          @current_token = GE
        else
          @current_token = GT
        end
      end
    end

    def scan_string(quote_byte)
      quote_pos = @scanner.pos
      @scanner.pos += 1  # skip opening quote
      start = @scanner.pos

      # Lax Liquid tolerates a doubled quote immediately after a complete string
      # argument (`"t"" | next_filter`). If a later quote appears, the junk quote
      # swallows that malformed filter segment and parsing resumes at the next
      # pipe; otherwise it is just skipped so the next filter can be read.
      if @error_mode == :lax && quote_pos > 0 && @source.getbyte(quote_pos - 1) == quote_byte
        next_quote = @source.index(quote_byte.chr, start)
        if next_quote
          next_pipe = @source.index("|", next_quote + 1)
          @scanner.pos = next_pipe || @source_bytes
        else
          @scanner.pos = start
        end
        @peeked = false
        return advance
      end

      # Find closing quote
      while (b = @source.getbyte(@scanner.pos)) && b != quote_byte
        @scanner.pos += 1
      end

      if @source.getbyte(@scanner.pos) == quote_byte
        @current_value = @source.byteslice(start, @scanner.pos - start)
        @scanner.pos += 1  # skip closing quote
        @current_token = STRING
      elsif @error_mode == :lax
        # Lax Liquid tolerates an extra unmatched quote after a complete string
        # argument (e.g. split:"t"" | reverse). Treat that quote as junk and
        # continue lexing from the valid suffix so later filters are still seen.
        @scanner.pos = start
        @peeked = false
        advance
      else
        raise SyntaxError, "Unterminated string at position #{start - 1}"
      end
    end

    def scan_number
      start = @scanner.pos

      # Optional negative sign
      @scanner.pos += 1 if @source.getbyte(@scanner.pos) == 45  # -

      # Check if this is actually a number (not just a minus sign)
      byte = @source.getbyte(@scanner.pos)
      unless byte && byte >= 48 && byte <= 57
        # Not a number — lone '-' is not valid; treat as end of expression
        @scanner.pos = start
        @current_token = EOF
        return EOF
      end

      # Consume digits
      while (byte = @source.getbyte(@scanner.pos)) && byte >= 48 && byte <= 57
        @scanner.pos += 1
      end

      # If a digit-starting token continues directly with identifier characters
      # (e.g. 123foo), Liquid laxly treats the whole token as a variable name.
      # Keep ordinary numeric literals numeric by only switching when the next
      # byte is a letter/underscore before any decimal part is consumed.
      byte = @source.getbyte(@scanner.pos)
      if @source.getbyte(start) != 45 && byte && ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95)
        while (byte = @source.getbyte(@scanner.pos)) &&
              ((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95)
          @scanner.pos += 1
        end
        @current_value = @source.byteslice(start, @scanner.pos - start)
        @current_token = IDENTIFIER
        return
      end

      # Check for decimal part
      if @source.getbyte(@scanner.pos) == 46  # .
        next_byte = @source.getbyte(@scanner.pos + 1)
        if next_byte && next_byte >= 48 && next_byte <= 57
          @scanner.pos += 1  # skip .
          while (byte = @source.getbyte(@scanner.pos)) && byte >= 48 && byte <= 57
            @scanner.pos += 1
          end
        end
      end

      @current_value = @source.byteslice(start, @scanner.pos - start)
      @current_token = NUMBER
    end

    # Identifier body after a valid first char: letters, digits, _, -, with an
    # optional trailing ?. One StringScanner#skip (C) replaces the per-byte
    # Ruby loop (~4x faster on typical identifiers).
    IDENT_RE = /[A-Za-z_][A-Za-z0-9_\-]*\??/

    def scan_identifier_or_keyword
      start = @scanner.pos
      src = @source

      # First char: a-z, A-Z, _ (also rejected by IDENT_RE, but the error
      # paths need the byte)
      len = @scanner.skip(IDENT_RE)
      unless len
        byte = src.getbyte(start)
        if @error_mode == :lax
          @scanner.pos = @source.bytesize
          @current_value = nil
          @current_token = EOF
          return
        end
        raise SyntaxError, "Unexpected character '#{byte&.chr}' at position #{start}"
      end

      pos = start + len
      # Lax quirk preserved from the byte-loop version: a non-ASCII byte
      # directly after the identifier ends the whole expression — unless the
      # identifier ended with '?', which terminated the old scan first.
      trailing = src.getbyte(pos)
      if trailing && trailing > 127 && src.getbyte(pos - 1) != 63
        @scanner.pos = @source.bytesize
      end
      first_byte = src.getbyte(start)

      # Perfect hash keyword lookup — no string allocation for the keyword check!
      # Disambiguate by length, then by first byte (all lowercase keywords have unique first bytes per length)
      # When matched, set @current_value to the frozen keyword string (no allocation)
      case len
      when 2
        # "or" — first byte 'o'=111
        if first_byte == 111 && src.getbyte(start + 1) == 114  # 'r'
          @current_token = OR
          @current_value = "or"
          return
        end
      when 3
        if (entry = KW_LEN3_TABLE[first_byte | 32])  # downcase first byte
          word = entry[0]
          if (src.getbyte(start + 1) | 32) == word.getbyte(1) &&
             (src.getbyte(start + 2) | 32) == word.getbyte(2)
            @current_token = entry[1]
            @current_value = word  # frozen string from table
            return
          end
        end
      when 4
        if (entry = KW_LEN4_TABLE[first_byte | 32])
          word = entry[0]
          if (src.getbyte(start + 1) | 32) == word.getbyte(1) &&
             (src.getbyte(start + 2) | 32) == word.getbyte(2) &&
             (src.getbyte(start + 3) | 32) == word.getbyte(3)
            @current_token = entry[1]
            @current_value = word
            return
          end
        end
      when 5
        if (entry = KW_LEN5_TABLE[first_byte | 32])
          word = entry[0]
          if (src.getbyte(start + 1) | 32) == word.getbyte(1) &&
             (src.getbyte(start + 2) | 32) == word.getbyte(2) &&
             (src.getbyte(start + 3) | 32) == word.getbyte(3) &&
             (src.getbyte(start + 4) | 32) == word.getbyte(4)
            @current_token = entry[1]
            @current_value = word
            return
          end
        end
      when 8
        # "contains" — verify byte-by-byte
        if (first_byte | 32) == 99  # 'c'
          match = true
          1.upto(7) do |i|
            unless (src.getbyte(start + i) | 32) == CONTAINS_BYTES[i]
              match = false
              break
            end
          end
          if match
            @current_token = CONTAINS
            @current_value = "contains"
            return
          end
        end
      end

      # Not a keyword — extract as identifier
      @current_value = src.byteslice(start, len)
      @current_token = IDENTIFIER
    end
  end
end
