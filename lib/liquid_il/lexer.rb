# frozen_string_literal: true

require "strscan"
require "string_view"

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
    end

    def reset
      @scanner.pos = 0
      @trim_next = false
      @token_type = nil
    end

    # Extract token content as a String.
    # For RAW tokens: the raw text (with trim applied if needed)
    # For TAG/VAR tokens: the markup between delimiters (stripped)
    def token_content
      if @token_type == RAW
        s = @source.byteslice(@content_start, @content_end - @content_start)
        @_needs_lstrip ? s.lstrip : s
      else
        @source.byteslice(@content_start, @content_end - @content_start).strip
      end
    end

    # Zero-copy StringView of RAW content — no allocation for the string itself.
    # Trim still needs byteslice when lstrip is required.
    def raw_content_view
      if @_needs_lstrip
        # Advance past leading whitespace in the view
        pos = @content_start
        limit = @content_end
        while pos < limit
          b = @source.getbyte(pos)
          break unless b == 32 || b == 9 || b == 10 || b == 13
          pos += 1
        end
        pos < limit ? StringView.new(@source, pos, limit - pos) : nil
      else
        len = @content_end - @content_start
        len > 0 ? StringView.new(@source, @content_start, len) : nil
      end
    end

    # Check if content region is all whitespace — zero allocation.
    # Replaces `token_content.strip.empty?` which allocates 2 strings.
    def content_blank?
      pos = @content_start
      limit = @content_end
      src = @source
      while pos < limit
        b = src.getbyte(pos)
        return false unless b == 32 || b == 9 || b == 10 || b == 13
        pos += 1
      end
      true
    end

    # Extract just the tag name from a TAG token — no content string allocation.
    # Scans bytes from content_start, skips leading whitespace, extracts first word, downcases.
    # Returns a frozen string (no allocation for common tag names).
    COMMON_TAGS = %w[if elsif else endif unless endunless for endfor case when endcase
                     assign capture endcapture comment endcomment raw endraw render include
                     increment decrement tablerow endtablerow cycle ifchanged break continue
                     liquid echo paginate endpaginate doc].each_with_object({}) { |t, h| h[t] = t.freeze }.freeze

    def tag_name
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

      len = pos - name_start
      # Fast path: check common tags by length + first byte, avoiding allocation
      # All common tags are lowercase ASCII, so we can match bytes directly
      first_byte = src.getbyte(name_start) | 32  # downcase
      tag = _match_common_tag(src, name_start, len, first_byte)
      return tag if tag

      # Slow path: extract and downcase (unknown tags only — very rare)
      name = src.byteslice(name_start, len)
      name.downcase
    end

    # Match common tag names by byte comparison — zero allocation.
    # Returns frozen string from COMMON_TAGS or nil.
    def _match_common_tag(src, start, len, first_byte) # :nodoc:
      case len
      when 1
        # # (inline comment)
        return "#" if first_byte == 35
      when 2
        # if
        return "if" if first_byte == 105 && (src.getbyte(start + 1) | 32) == 102
        # do — not a tag, but handle "or" length match
      when 3
        case first_byte
        when 100 # doc
          return "doc" if (src.getbyte(start + 1) | 32) == 111 && (src.getbyte(start + 2) | 32) == 99
        when 102 # for
          return "for" if (src.getbyte(start + 1) | 32) == 111 && (src.getbyte(start + 2) | 32) == 114
        when 114 # raw
          return "raw" if (src.getbyte(start + 1) | 32) == 97 && (src.getbyte(start + 2) | 32) == 119
        end
      when 4
        case first_byte
        when 99  # case
          return "case" if (src.getbyte(start + 1) | 32) == 97 && (src.getbyte(start + 2) | 32) == 115 && (src.getbyte(start + 3) | 32) == 101
        when 101 # echo, else
          b1 = src.getbyte(start + 1) | 32
          if b1 == 99 # echo
            return "echo" if (src.getbyte(start + 2) | 32) == 104 && (src.getbyte(start + 3) | 32) == 111
          elsif b1 == 108 # else
            return "else" if (src.getbyte(start + 2) | 32) == 115 && (src.getbyte(start + 3) | 32) == 101
          end
        when 119 # when
          return "when" if (src.getbyte(start + 1) | 32) == 104 && (src.getbyte(start + 2) | 32) == 101 && (src.getbyte(start + 3) | 32) == 110
        end
      when 5
        case first_byte
        when 101 # endif
          if (src.getbyte(start + 1) | 32) == 110
            return "endif" if (src.getbyte(start + 2) | 32) == 100 && (src.getbyte(start + 3) | 32) == 105 && (src.getbyte(start + 4) | 32) == 102
          end
        when 99  # cycle
          return "cycle" if (src.getbyte(start + 1) | 32) == 121 && (src.getbyte(start + 2) | 32) == 99 && (src.getbyte(start + 3) | 32) == 108 && (src.getbyte(start + 4) | 32) == 101
        end
      when 6
        case first_byte
        when 97  # assign
          return "assign" if _bytes_match_ci?(src, start, "assign")
        when 101 # endfor, endraw, elsif
          b1 = src.getbyte(start + 1) | 32
          if b1 == 110 # endfor, endraw
            return "endfor" if _bytes_match_ci?(src, start, "endfor")
          elsif b1 == 108 # elsif
            return "elsif" if _bytes_match_ci?(src, start, "elsif")
          end
        when 114 # render
          return "render" if _bytes_match_ci?(src, start, "render")
        when 108 # liquid
          return "liquid" if _bytes_match_ci?(src, start, "liquid")
        end
      when 7
        case first_byte
        when 99  # capture, comment
          b1 = src.getbyte(start + 1) | 32
          if b1 == 97 # capture
            return "capture" if _bytes_match_ci?(src, start, "capture")
          elsif b1 == 111 # comment
            return "comment" if _bytes_match_ci?(src, start, "comment")
          end
        when 101 # endcase
          return "endcase" if _bytes_match_ci?(src, start, "endcase")
        when 105 # include, ifchanged — wait, ifchanged is 9
          return "include" if _bytes_match_ci?(src, start, "include")
        when 117 # unless
          return "unless" if _bytes_match_ci?(src, start, "unless")
        end
      when 8
        case first_byte
        when 112 # paginate
          return "paginate" if _bytes_match_ci?(src, start, "paginate")
        when 116 # tablerow
          return "tablerow" if _bytes_match_ci?(src, start, "tablerow")
        end
      when 9
        case first_byte
        when 101 # endunless, increment, decrement
          return "endunless" if _bytes_match_ci?(src, start, "endunless")
        when 105 # increment, ifchanged
          b1 = src.getbyte(start + 1) | 32
          if b1 == 110 # increment
            return "increment" if _bytes_match_ci?(src, start, "increment")
          elsif b1 == 102 # ifchanged
            return "ifchanged" if _bytes_match_ci?(src, start, "ifchanged")
          end
        when 100 # decrement
          return "decrement" if _bytes_match_ci?(src, start, "decrement")
        end
      when 10
        case first_byte
        when 101 # endcapture, endcomment, endtablerow — endcomment is 10
          return "endcomment" if _bytes_match_ci?(src, start, "endcomment")
          return "endcapture" if _bytes_match_ci?(src, start, "endcapture")
        end
      when 11
        # endtablerow
        return "endtablerow" if first_byte == 101 && _bytes_match_ci?(src, start, "endtablerow")
      when 13
        # endpaginate
        return "endpaginate" if first_byte == 101 && _bytes_match_ci?(src, start, "endpaginate")
      end
      nil
    end

    # Case-insensitive byte comparison against a known lowercase word.
    # Zero allocation.
    def _bytes_match_ci?(src, start, word) # :nodoc:
      i = 1 # first byte already checked by caller
      while i < word.bytesize
        return false unless (src.getbyte(start + i) | 32) == word.getbyte(i)
        i += 1
      end
      true
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

    # Legacy compatibility: returns [type, content, trim_left, trim_right, start_pos, end_pos]
    def next_token_tuple
      type = next_token
      [type, token_content, @trim_left, @trim_right, @token_start, @token_end]
    end

    # Tokenize entire template into array of tuples (legacy)
    def tokenize
      reset
      tokens = []
      loop do
        type = next_token
        break if type == EOF
        tokens << [type, token_content, @trim_left, @trim_right, @token_start, @token_end]
      end
      tokens
    end

    private

    def scan_raw_token
      start_pos = @scanner.pos
      @_needs_lstrip = @trim_next
      @trim_next = false

      # Scan byte-by-byte looking for '{' followed by '{' or '%'
      pos = start_pos
      src = @source
      limit = @source_bytes
      while pos < limit
        if src.getbyte(pos) == 123  # '{'
          b1 = src.getbyte(pos + 1)
          if b1 == 123 || b1 == 37  # '{' or '%'
            break
          end
        end
        pos += 1
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

    # Keywords — all lowercase, lengths 2-8
    # We use a perfect hash to avoid .downcase allocation.
    #
    # Keywords and their 2nd+3rd bytes (as 16-bit LE int):
    #   nil(2)→skip  null(3)→"ul"  true(3)→"ru"  false(4)→"al"
    #   empty(4)→"mp"  blank(4)→"la"  and(2)→skip  or(1)→skip
    #   contains(7)→"on"
    #
    # For len=3: "ul"=27765, "ru"=30066  → unique by byte pair
    # For len=4: "al"=27745, "mp"=28781, "la"=24940  → unique
    # For len=5: "al"=27745 (false) — collision with blank? No: false len=5, blank len=5
    #   false→"al"=27745, blank→"la"=24940, empty→"mp"=28781 → unique
    # For len=8: "on"=28527 (contains) → unique
    #
    # Actually let's just build the table properly.

    # Build perfect hash for keywords
    # Strategy: length disambiguates most, then 2nd byte for collisions
    KW_BY_LEN = {}.tap do |h|
      { "nil" => NIL, "null" => NIL, "true" => TRUE, "false" => FALSE,
        "empty" => EMPTY, "blank" => BLANK, "and" => AND, "or" => OR,
        "contains" => CONTAINS }.each do |word, tok|
        (h[word.length] ||= []) << [word, tok]
      end
    end.freeze

    # For lengths with multiple keywords, build byte-based disambiguation
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

    # Legacy hash for fallback (case-insensitive)
    KEYWORDS = {
      "nil" => NIL, "null" => NIL, "true" => TRUE, "false" => FALSE,
      "empty" => EMPTY, "blank" => BLANK, "and" => AND, "or" => OR,
      "contains" => CONTAINS,
    }.freeze

    CONTAINS_BYTES = "contains".bytes.freeze

    # Pre-compiled patterns
    WHITESPACE = /\s+/

    def initialize(source = "", intern_table: nil)
      @source = source
      @source_len = source.bytesize
      @pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
      @intern = intern_table  # Shared string intern table for identifier dedup
    end

    # Reset to scan a new source substring.
    def reset_source(source)
      @source = source
      @source_len = source.bytesize
      @pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
      self
    end

    # Reset to scan a region of a source string — zero allocation.
    # Uses absolute positions: @pos starts at offset, stops at offset+length.
    # getbyte/byteslice work because @source is the full string.
    def reset_region(source, offset, length)
      @source = source
      @pos = offset
      @source_len = offset + length
      @current_token = nil
      @current_value = nil
      @peeked = false
      self
    end

    def reset
      @pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
    end

    # Save current lexer state for backtracking
    def save_state
      { pos: @pos, token: @current_token, value: @current_value, peeked: @peeked }
    end

    # Restore lexer state from saved state
    def restore_state(state)
      @pos = state[:pos]
      @current_token = state[:token]
      @current_value = state[:value]
      @peeked = state[:peeked]
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
      pos = @pos
      while (b = @source.getbyte(pos)) && (b == 32 || b == 9 || b == 10 || b == 13)
        pos += 1
      end
      @pos = pos

      if pos >= @source_len
        @current_token = EOF
        @peeked = true
        return EOF
      end

      byte = @source.getbyte(pos)

      # Check punctuation table first (most common)
      if (punct = PUNCT_TABLE[byte])
        scan_punctuation(punct)
      elsif (comp = COMP_TABLE[byte])
        scan_comparison(comp)
      elsif byte == 39 || byte == 34  # ' or "
        scan_string(byte)
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
        raise SyntaxError, "Expected #{token_type} but got #{current} at position #{@pos}"
      end
    end

    def eos?
      current == EOF
    end

    private

    def scan_punctuation(punct)
      if punct == :DOT_OR_DOTDOT
        next_byte = @source.getbyte(@pos + 1)
        if next_byte == 46 # another . -> DOTDOT
          @pos += 2
          @current_token = DOTDOT
        elsif next_byte && next_byte >= 48 && next_byte <= 57 # digit -> float like .5
          scan_leading_decimal_number
        else
          @pos += 1
          @current_token = DOT
        end
      else
        @pos += 1
        @current_token = punct
      end
    end

    # Scan number starting with decimal like .5
    def scan_leading_decimal_number
      start = @pos
      @pos += 1 # skip .
      # Consume digits
      while (byte = @source.getbyte(@pos)) && byte >= 48 && byte <= 57
        @pos += 1
      end
      @current_value = _intern_identifier(@source, start, @pos - start)
      @current_token = NUMBER
    end

    def scan_comparison(comp)
      case comp
      when :EQ_START
        @pos += 1
        next_byte = @source.getbyte(@pos)
        if next_byte == 61  # =
          @pos += 1
          @current_token = EQ
        elsif next_byte == 62  # > (fat arrow for lax parsing)
          @pos += 1
          @current_token = FAT_ARROW
        else
          raise SyntaxError, "Expected '==' at position #{@pos - 1}"
        end
      when :NE_START
        @pos += 1
        if @source.getbyte(@pos) == 61  # =
          @pos += 1
          @current_token = NE
        else
          raise SyntaxError, "Expected '!=' at position #{@pos - 1}"
        end
      when :LT_START
        @pos += 1
        if @source.getbyte(@pos) == 61  # =
          @pos += 1
          @current_token = LE
        elsif @source.getbyte(@pos) == 62  # >
          @pos += 1
          @current_token = NE  # <> is also !=
        else
          @current_token = LT
        end
      when :GT_START
        @pos += 1
        if @source.getbyte(@pos) == 61  # =
          @pos += 1
          @current_token = GE
        else
          @current_token = GT
        end
      end
    end

    def scan_string(quote_byte)
      @pos += 1  # skip opening quote
      start = @pos

      # Find closing quote
      while (b = @source.getbyte(@pos)) && b != quote_byte
        @pos += 1
      end

      if @source.getbyte(@pos) == quote_byte
        @current_value = _intern_identifier(@source, start, @pos - start)
        @pos += 1  # skip closing quote
        @current_token = STRING
      else
        raise SyntaxError, "Unterminated string at position #{start - 1}"
      end
    end

    def scan_number
      start = @pos

      # Optional negative sign
      @pos += 1 if @source.getbyte(@pos) == 45  # -

      # Check if this is actually a number (not just a minus sign)
      byte = @source.getbyte(@pos)
      unless byte && byte >= 48 && byte <= 57
        # Not a number, back up and try identifier
        @pos = start
        return scan_identifier_or_keyword
      end

      # Consume digits
      while (byte = @source.getbyte(@pos)) && byte >= 48 && byte <= 57
        @pos += 1
      end

      # Check for decimal part
      if @source.getbyte(@pos) == 46  # .
        next_byte = @source.getbyte(@pos + 1)
        if next_byte && next_byte >= 48 && next_byte <= 57
          @pos += 1  # skip .
          while (byte = @source.getbyte(@pos)) && byte >= 48 && byte <= 57
            @pos += 1
          end
        end
      end

      @current_value = _intern_identifier(@source, start, @pos - start)
      @current_token = NUMBER
    end

    def scan_identifier_or_keyword
      start = @pos
      src = @source

      # First char: a-z, A-Z, _
      byte = src.getbyte(start)
      unless byte && (byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95)
        raise SyntaxError, "Unexpected character '#{byte&.chr}' at position #{start}"
      end

      pos = start + 1

      # Rest: a-z, A-Z, 0-9, _, -
      while (byte = src.getbyte(pos))
        if byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 ||
           byte >= 48 && byte <= 57 || byte == 95 || byte == 45
          pos += 1
        elsif byte == 63  # ? at end
          pos += 1
          break
        else
          break
        end
      end

      @pos = pos
      len = pos - start
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

      # Not a keyword — intern for dedup (avoids repeated byteslice for same identifiers)
      @current_value = _intern_identifier(src, start, len)
      @current_token = IDENTIFIER
    end

    private

    # Intern an identifier: return a cached frozen string if the same bytes
    # were seen before. First occurrence allocates; subsequent are free.
    def _intern_identifier(src, start, len)
      table = @intern
      unless table
        # No intern table — fallback to direct byteslice
        return src.byteslice(start, len)
      end

      # Compute FNV-1a hash of the bytes for fast lookup
      h = 0x811c9dc5
      i = 0
      while i < len
        h ^= src.getbyte(start + i)
        h = (h * 0x01000193) & 0xFFFFFFFF
        i += 1
      end

      # Combine hash with length for the key
      key = (h << 8) | len

      if (cached = table[key])
        # Verify match (hash collision guard)
        if cached.bytesize == len
          match = true
          i = 0
          while i < len
            if src.getbyte(start + i) != cached.getbyte(i)
              match = false
              break
            end
            i += 1
          end
          return cached if match
        end
        # Hash collision — fall through to byteslice
      end

      str = src.byteslice(start, len).freeze
      table[key] = str
      str
    end
  end
end
