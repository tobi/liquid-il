# frozen_string_literal: true

module LiquidIL
  # Lightweight lexer that implements the TemplateLexer duck-type interface
  # for use inside {% liquid %} tags. Given the liquid tag's content string,
  # it emits one TAG token per non-empty, non-comment line.
  #
  # This allows parse_block_body → parse_tag to handle all tags uniformly,
  # eliminating the need for parallel parse_*_in_liquid methods.
  class LiquidBodyLexer
    TAG = TemplateLexer::TAG
    EOF = TemplateLexer::EOF

    attr_reader :source, :token_type, :token_start, :token_end,
                :content_start, :content_end, :trim_left, :trim_right

    def initialize(content)
      @source = content
      @lines = split_lines(content)
      @line_idx = 0
      @token_type = nil
      @token_start = 0
      @token_end = 0
      @content_start = 0
      @content_end = 0
      @trim_left = false
      @trim_right = false
    end

    def next_token
      # Skip empty and comment lines
      while @line_idx < @lines.size
        start, finish, stripped = @lines[@line_idx]
        @line_idx += 1

        # Skip empty lines and # comments
        next if stripped.empty? || stripped.start_with?("#")

        @token_type = TAG
        @token_start = start
        @token_end = finish
        @content_start = start
        @content_end = finish
        @trim_left = false
        @trim_right = false
        return TAG
      end

      @token_type = EOF
      @token_start = @source.bytesize
      @token_end = @source.bytesize
      @content_start = @source.bytesize
      @content_end = @source.bytesize
      EOF
    end

    def token_content
      @source.byteslice(@content_start, @content_end - @content_start).strip
    end

    def tag_name
      src = @source
      pos = @content_start
      limit = @content_end

      # Skip leading whitespace
      while pos < limit
        b = src.getbyte(pos)
        break unless b == 32 || b == 9 || b == 10 || b == 13
        pos += 1
      end

      # Find end of tag name
      name_start = pos
      while pos < limit
        b = src.getbyte(pos)
        break if b == 32 || b == 9 || b == 10 || b == 13
        pos += 1
      end

      return nil if pos == name_start

      name = src.byteslice(name_start, pos - name_start)
      TemplateLexer::COMMON_TAGS[name] || name.downcase
    end

    private

    # Pre-compute line boundaries as [start_byte, end_byte, stripped_content]
    # so next_token is just index bumping.
    def split_lines(content)
      lines = []
      pos = 0
      content.each_line do |line|
        line_bytes = line.bytesize
        # Strip the trailing newline for content_end
        end_pos = pos + line_bytes
        # Trim trailing newline/cr from the content region
        trimmed_end = end_pos
        while trimmed_end > pos && (b = content.getbyte(trimmed_end - 1)) && (b == 10 || b == 13)
          trimmed_end -= 1
        end
        stripped = line.strip
        lines << [pos, trimmed_end, stripped]
        pos = end_pos
      end
      lines
    end
  end
end
