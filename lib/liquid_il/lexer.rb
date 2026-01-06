# frozen_string_literal: true

require "strscan"

module LiquidIL
  # High-performance template tokenizer
  # Stage 1: Splits template into RAW, TAG, and VAR tokens
  class TemplateLexer
    RAW = :RAW
    TAG = :TAG
    VAR = :VAR
    EOF = :EOF

    # Regex patterns - pre-compiled for performance
    TAG_START = /\{%-?/
    VAR_START = /\{\{-?/
    TAG_END = /-?%\}/
    VAR_END = /-?\}\}/

    # Combined pattern to find next delimiter
    NEXT_DELIM = /\{[{%]-?/

    # Pattern to find endraw (with optional whitespace and trim)
    ENDRAW_PATTERN = /\{%-?\s*endraw\s*-?%\}/

    def initialize(source)
      @source = source
      @scanner = StringScanner.new(source)
      @trim_next = false
    end

    def reset
      @scanner.pos = 0
      @trim_next = false
    end

    # Scan raw content until {% endraw %}
    # Returns [content, trim_left, trim_right] or nil if no endraw found
    # Note: trim_next from {% raw -%} is intentionally NOT applied to raw content
    def scan_raw_body
      start_pos = @scanner.pos
      # Reset trim_next - it shouldn't affect raw content
      @trim_next = false

      # Find {% endraw %}
      if @scanner.skip_until(ENDRAW_PATTERN)
        match = @scanner.matched
        content_end = @scanner.pos - match.length
        content = @source.byteslice(start_pos, content_end - start_pos)

        # Check for trim markers on endraw
        trim_left = match.include?("{%-")
        trim_right = match.include?("-%}")

        # Set trim_next for the token after endraw
        @trim_next = trim_right

        [content, trim_left, trim_right]
      else
        nil
      end
    end

    # Returns [type, content, trim_left, trim_right, start_pos, end_pos]
    # Uses lazy extraction - only extracts content when needed
    def next_token
      return [EOF, nil, false, false, @scanner.pos, @scanner.pos] if @scanner.eos?

      # Try to find next delimiter
      if @scanner.check(NEXT_DELIM)
        scan_liquid_token
      else
        scan_raw_token
      end
    end

    # Tokenize entire template into array
    def tokenize
      reset
      tokens = []
      loop do
        token = next_token
        break if token[0] == EOF
        tokens << token
      end
      tokens
    end

    private

    def scan_raw_token
      start_pos = @scanner.pos

      # Scan until we hit a delimiter or end
      @scanner.skip_until(NEXT_DELIM)
      if @scanner.matched
        # Back up to before the delimiter
        @scanner.pos -= @scanner.matched.length
        end_pos = @scanner.pos
      else
        # No more delimiters, consume rest
        @scanner.terminate
        end_pos = @source.length
      end

      content = @source.byteslice(start_pos, end_pos - start_pos)

      # Apply trim from previous token
      if @trim_next && content
        content = content.lstrip
        @trim_next = false
      end

      [RAW, content, false, false, start_pos, end_pos]
    end

    def scan_liquid_token
      start_pos = @scanner.pos

      # Determine token type and trim_left
      if @scanner.skip(/\{\{-/)
        type = VAR
        trim_left = true
      elsif @scanner.skip(/\{\{/)
        type = VAR
        trim_left = false
      elsif @scanner.skip(/\{%-/)
        type = TAG
        trim_left = true
      elsif @scanner.skip(/\{%/)
        type = TAG
        trim_left = false
      else
        raise SyntaxError, "Unexpected state in lexer at position #{@scanner.pos}"
      end

      content_start = @scanner.pos

      # Find matching end delimiter
      end_pattern = type == VAR ? VAR_END : TAG_END

      if @scanner.skip_until(end_pattern)
        # Extract content (without end delimiter)
        match = @scanner.matched
        content_end = @scanner.pos - match.length
        content = @source.byteslice(content_start, content_end - content_start)
        end_pos = @scanner.pos

        # Determine trim_right
        trim_right = match.start_with?("-")
        @trim_next = trim_right

        [type, content.strip, trim_left, trim_right, start_pos, end_pos]
      else
        raise SyntaxError, "Unterminated #{type == VAR ? 'variable' : 'tag'} at position #{start_pos}"
      end
    end
  end

  # High-performance expression lexer
  # Stage 2: Tokenizes tag/variable markup
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

    # Keywords (case-insensitive literals)
    KEYWORDS = {
      "nil" => NIL,
      "null" => NIL,
      "true" => TRUE,
      "false" => FALSE,
      "empty" => EMPTY,
      "blank" => BLANK,
      "and" => AND,
      "or" => OR,
      "contains" => CONTAINS,
    }.freeze

    # Pre-compiled patterns
    WHITESPACE = /\s+/
    IDENTIFIER_PATTERN = /[a-zA-Z_][a-zA-Z0-9_\-]*\??/
    NUMBER_PATTERN = /-?\d+(?:\.\d+)?/
    STRING_SINGLE = /'([^']*)'/
    STRING_DOUBLE = /"([^"]*)"/

    def initialize(source)
      @source = source
      @scanner = StringScanner.new(source)
      @current_token = nil
      @current_value = nil
      @peeked = false
    end

    def reset
      @scanner.pos = 0
      @current_token = nil
      @current_value = nil
      @peeked = false
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

      # Skip whitespace
      @scanner.skip(WHITESPACE)

      if @scanner.eos?
        @current_token = EOF
        @peeked = true
        return EOF
      end

      byte = @source.getbyte(@scanner.pos)

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
          @scanner.pos += 2
          @current_token = DOTDOT
        elsif next_byte && next_byte >= 48 && next_byte <= 57 # digit -> float like .5
          scan_leading_decimal_number
        else
          @scanner.pos += 1
          @current_token = DOT
        end
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
        if @source.getbyte(@scanner.pos) == 61  # =
          @scanner.pos += 1
          @current_token = EQ
        else
          raise SyntaxError, "Expected '==' at position #{@scanner.pos - 1}"
        end
      when :NE_START
        @scanner.pos += 1
        if @source.getbyte(@scanner.pos) == 61  # =
          @scanner.pos += 1
          @current_token = NE
        else
          raise SyntaxError, "Expected '!=' at position #{@scanner.pos - 1}"
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
      @scanner.pos += 1  # skip opening quote
      start = @scanner.pos

      # Find closing quote
      while (b = @source.getbyte(@scanner.pos)) && b != quote_byte
        @scanner.pos += 1
      end

      if @source.getbyte(@scanner.pos) == quote_byte
        @current_value = @source.byteslice(start, @scanner.pos - start)
        @scanner.pos += 1  # skip closing quote
        @current_token = STRING
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
        # Not a number, back up and try identifier
        @scanner.pos = start
        return scan_identifier_or_keyword
      end

      # Consume digits
      while (byte = @source.getbyte(@scanner.pos)) && byte >= 48 && byte <= 57
        @scanner.pos += 1
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

    def scan_identifier_or_keyword
      start = @scanner.pos

      # First char: a-z, A-Z, _
      byte = @source.getbyte(@scanner.pos)
      unless byte && (byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95)
        raise SyntaxError, "Unexpected character '#{byte&.chr}' at position #{@scanner.pos}"
      end

      @scanner.pos += 1

      # Rest: a-z, A-Z, 0-9, _, -
      while (byte = @source.getbyte(@scanner.pos))
        if byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 ||
           byte >= 48 && byte <= 57 || byte == 95 || byte == 45
          @scanner.pos += 1
        elsif byte == 63  # ? at end
          @scanner.pos += 1
          break
        else
          break
        end
      end

      @current_value = @source.byteslice(start, @scanner.pos - start)

      # Check for keyword
      if (kw = KEYWORDS[@current_value.downcase])
        @current_token = kw
      else
        @current_token = IDENTIFIER
      end
    end
  end
end
