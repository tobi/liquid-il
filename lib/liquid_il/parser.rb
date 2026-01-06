# frozen_string_literal: true

module LiquidIL
  # Recursive descent parser that emits IL directly
  class Parser
    attr_reader :builder

    # Filter aliases - resolved at compile time (lowering)
    FILTER_ALIASES = {
      'h' => 'escape'
    }.freeze
    WHITESPACE_ONLY = /\A[ \t\r\n]*\z/

    def initialize(source)
      @source = source
      @template_lexer = TemplateLexer.new(source)
      @builder = IL::Builder.new
      @current_token = nil
      @loop_stack = []
      @blank_raw_indices_stack = []
      @cycle_counter = 0 # For unique cycle identities
    end

    def parse
      @template_lexer.reset
      advance_template
      parse_block_body(nil)
      @builder.halt
      IL.link(@builder.instructions)
    end

    private

    def advance_template
      @current_token = @template_lexer.next_token
    end

    def current_template_type
      @current_token[0]
    end

    def current_template_content
      @current_token[1]
    end

    def current_template_trim_left
      @current_token[2]
    end

    def current_template_trim_right
      @current_token[3]
    end

    def current_template_start_pos
      @current_token[4]
    end

    def current_template_end_pos
      @current_token[5]
    end

    def parse_block_body(end_tags)
      @builder.clear_span # Body content shouldn't inherit tag's span
      blank = true
      raw_indices = push_blank_raw_indices
      begin
        until template_eos?
          # Safety: track position to detect infinite loops
          prev_pos = current_template_start_pos

          case current_template_type
          when TemplateLexer::RAW
            blank = parse_raw && blank
          when TemplateLexer::VAR
            trim_previous_raw if current_template_trim_left
            parse_variable_output
            blank = false
          when TemplateLexer::TAG
            trim_previous_raw if current_template_trim_left
            tag_name = tag_name_from_content(current_template_content)

            # Check if this is an end tag we're looking for
            return [tag_name, blank, raw_indices] if end_tags && end_tags.include?(tag_name)

            tag_blank = parse_tag
            blank = tag_blank && blank
          end

          # Safety: raise if we didn't advance (indicates infinite loop bug)
          if current_template_start_pos == prev_pos && !template_eos?
            raise "Parser bug: infinite loop detected at position #{prev_pos}"
          end
        end
        [nil, blank, raw_indices]
      ensure
        pop_blank_raw_indices
      end
    end

    def template_eos?
      current_template_type == TemplateLexer::EOF
    end

    def tag_name_from_content(content)
      content.split(/\s+/, 2).first&.downcase
    end

    # Skip to a specific end tag without emitting IL (for error recovery)
    def skip_to_end_tag(end_tag_name)
      depth = 1
      while !template_eos? && depth > 0
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          # Track nesting for tags that can nest
          case tag_name
          when 'if', 'unless', 'case', 'for', 'tablerow', 'capture', 'comment'
            depth += 1
          when 'endif', 'endunless', 'endcase', 'endfor', 'endtablerow', 'endcapture', 'endcomment'
            if tag_name == end_tag_name && depth == 1
              advance_template
              return
            end
            depth -= 1
          end
        end
        advance_template
      end
    end

    def parse_raw
      content = current_template_content
      emit_raw(content) unless content.empty?
      advance_template
      content.empty? || content.match?(WHITESPACE_ONLY)
    end

    def parse_variable_output
      content = current_template_content
      @builder.with_span(current_template_start_pos, current_template_end_pos)

      expr_lexer = ExpressionLexer.new(content)
      expr_lexer.advance

      parse_expression(expr_lexer)
      parse_filters(expr_lexer)
      @builder.write_value

      @builder.clear_span
      expect_eos(expr_lexer)
      advance_template
      false
    end

    def parse_tag
      content = current_template_content
      start_pos = current_template_start_pos
      end_pos = current_template_end_pos
      parts = content.split(/\s+/, 2)
      tag_name = parts[0]&.downcase
      tag_args = parts[1] || ''

      @builder.with_span(start_pos, end_pos)

      case tag_name
      when 'if'
        advance_template
        parse_if_tag(tag_args)
      when 'unless'
        advance_template
        parse_unless_tag(tag_args)
      when 'case'
        advance_template
        parse_case_tag(tag_args)
      when 'for'
        advance_template
        parse_for_tag(tag_args)
      when 'tablerow'
        advance_template
        parse_tablerow_tag(tag_args)
      when 'assign'
        advance_template
        parse_assign_tag(tag_args)
      when 'capture'
        advance_template
        parse_capture_tag(tag_args)
      when 'increment'
        advance_template
        parse_increment_tag(tag_args)
      when 'decrement'
        advance_template
        parse_decrement_tag(tag_args)
      when 'cycle'
        advance_template
        parse_cycle_tag(tag_args)
      when 'break'
        advance_template
        emit_loop_jump(:break)
        false
      when 'continue'
        advance_template
        emit_loop_jump(:continue)
        false
      when 'echo'
        advance_template
        parse_echo_tag(tag_args)
      when 'liquid'
        advance_template
        parse_liquid_tag(tag_args)
      when 'raw'
        # Don't advance_template - parse_raw_tag uses lexer directly
        parse_raw_tag
      when 'comment'
        advance_template
        parse_comment_tag
      when 'doc'
        advance_template
        parse_doc_tag
      when 'render'
        advance_template
        parse_render_tag(tag_args)
      when 'include'
        advance_template
        parse_include_tag(tag_args)
      when '#'
        # Inline comment, skip
        advance_template
        true
      else
        # Unknown tag - skip for now
        advance_template
        false
      end.tap { @builder.clear_span }
    end

    def emit_raw(content)
      @builder.write_raw(content)
      return unless current_blank_raw_indices && content.match?(WHITESPACE_ONLY)

      current_blank_raw_indices << (@builder.instructions.length - 1)
    end

    def trim_previous_raw
      last = @builder.instructions.last
      return unless last && last[0] == IL::WRITE_RAW

      trimmed = last[1].rstrip
      if trimmed.empty?
        @builder.instructions[-1] = [IL::NOOP]
      else
        last[1] = trimmed
      end
    end

    def strip_blank_raws(indices)
      indices.each do |idx|
        inst = @builder.instructions[idx]
        next unless inst && inst[0] == IL::WRITE_RAW

        @builder.instructions[idx] = [IL::NOOP]
      end
    end

    def push_blank_raw_indices
      arr = []
      @blank_raw_indices_stack.push(arr)
      arr
    end

    def pop_blank_raw_indices
      @blank_raw_indices_stack.pop
    end

    def current_blank_raw_indices
      @blank_raw_indices_stack.last
    end

    def emit_loop_jump(type)
      loop_ctx = @loop_stack.last
      unless loop_ctx
        @builder.push_interrupt(type)
        return
      end

      label = type == :break ? loop_ctx[:break] : loop_ctx[:continue]
      @builder.jump(label)
    end

    # --- Expression parsing ---

    def parse_expression(lexer)
      parse_or_expression(lexer)
    end

    def parse_or_expression(lexer)
      parse_and_expression(lexer)

      while lexer.current == ExpressionLexer::OR
        lexer.advance
        label_true = @builder.new_label
        label_end = @builder.new_label

        @builder.jump_if_true(label_true)
        parse_and_expression(lexer)
        @builder.jump(label_end)
        @builder.label(label_true)
        @builder.const_true
        @builder.label(label_end)
      end
    end

    def parse_and_expression(lexer)
      parse_comparison_expression(lexer)

      while lexer.current == ExpressionLexer::AND
        lexer.advance
        label_false = @builder.new_label
        label_end = @builder.new_label

        @builder.jump_if_false(label_false)
        parse_comparison_expression(lexer)
        @builder.jump(label_end)
        @builder.label(label_false)
        @builder.const_false
        @builder.label(label_end)
      end
    end

    def parse_comparison_expression(lexer)
      parse_primary_expression(lexer)

      loop do
        case lexer.current
        when ExpressionLexer::EQ
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:eq)
        when ExpressionLexer::NE
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:ne)
        when ExpressionLexer::LT
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:lt)
        when ExpressionLexer::LE
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:le)
        when ExpressionLexer::GT
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:gt)
        when ExpressionLexer::GE
          lexer.advance
          parse_primary_expression(lexer)
          @builder.compare(:ge)
        when ExpressionLexer::CONTAINS
          lexer.advance
          parse_primary_expression(lexer)
          @builder.contains
        else
          break
        end
      end
    end

    def parse_primary_expression(lexer)
      case lexer.current
      when ExpressionLexer::NIL, ExpressionLexer::TRUE, ExpressionLexer::FALSE,
           ExpressionLexer::EMPTY, ExpressionLexer::BLANK
        # Keywords can be variable names when followed by property access
        keyword_value = lexer.value # Store original value
        keyword_token = lexer.current
        lexer.advance
        if [ExpressionLexer::DOT, ExpressionLexer::LBRACKET].include?(lexer.current)
          # Treat as variable name
          @builder.find_var(keyword_value)
          parse_property_chain(lexer)
        else
          # Treat as keyword literal
          case keyword_token
          when ExpressionLexer::NIL
            @builder.const_nil
          when ExpressionLexer::TRUE
            @builder.const_true
          when ExpressionLexer::FALSE
            @builder.const_false
          when ExpressionLexer::EMPTY
            @builder.const_empty
          when ExpressionLexer::BLANK
            @builder.const_blank
          end
        end
      when ExpressionLexer::NUMBER
        parse_number(lexer)
      when ExpressionLexer::STRING
        @builder.const_string(lexer.value)
        lexer.advance
      when ExpressionLexer::LPAREN
        parse_range_or_grouped(lexer)
      when ExpressionLexer::IDENTIFIER
        parse_variable_lookup(lexer)
      when ExpressionLexer::LBRACKET
        # Dynamic root lookup - {{ [key] }} looks up key, then looks up that value in context
        lexer.advance
        parse_expression(lexer)
        lexer.expect(ExpressionLexer::RBRACKET)
        @builder.find_var_dynamic
        parse_property_chain(lexer)
      else
        raise SyntaxError, "Unexpected token #{lexer.current} in expression"
      end
    end

    def parse_number(lexer)
      val_str = lexer.value
      if val_str.include?('.')
        @builder.const_float(val_str.to_f)
      else
        @builder.const_int(val_str.to_i)
      end
      lexer.advance
    end

    def parse_variable_lookup(lexer)
      name = lexer.value
      lexer.advance

      # Check for command optimizations
      if %w[size first last].include?(name) && lexer.current != ExpressionLexer::DOT && lexer.current != ExpressionLexer::LBRACKET
        # This is a variable, not a command
        @builder.find_var(name)
      else
        @builder.find_var(name)
      end

      parse_property_chain(lexer)
    end

    def parse_property_chain(lexer)
      loop do
        case lexer.current
        when ExpressionLexer::DOT
          lexer.advance
          raise SyntaxError, "Expected property name after '.'" unless lexer.current == ExpressionLexer::IDENTIFIER

          prop_name = lexer.value
          lexer.advance
          @builder.lookup_const_key(prop_name)

        when ExpressionLexer::LBRACKET
          lexer.advance
          parse_expression(lexer)
          lexer.expect(ExpressionLexer::RBRACKET)
          @builder.lookup_key

        when ExpressionLexer::FAT_ARROW
          # Lax parsing: foo=>bar is equivalent to foo['bar']
          lexer.advance
          raise SyntaxError, "Expected property name after '=>'" unless lexer.current == ExpressionLexer::IDENTIFIER

          prop_name = lexer.value
          lexer.advance
          @builder.const_string(prop_name)
          @builder.lookup_key
        else
          break
        end
      end
    end

    def parse_range_or_grouped(lexer)
      lexer.advance # consume (

      # Parse first expression
      parse_expression(lexer)

      if lexer.current == ExpressionLexer::DOTDOT
        lexer.advance
        # This is a range
        parse_expression(lexer)
        lexer.expect(ExpressionLexer::RPAREN)
        @builder.new_range
      else
        # Just a grouped expression
        lexer.expect(ExpressionLexer::RPAREN)
      end
    end

    def parse_filters(lexer)
      while lexer.current == ExpressionLexer::PIPE
        lexer.advance
        parse_filter(lexer)
      end
    end

    def parse_filter(lexer)
      raise SyntaxError, "Expected filter name after '|'" unless lexer.current == ExpressionLexer::IDENTIFIER

      filter_name = lexer.value
      lexer.advance

      # Parse arguments if present
      argc = 0
      if lexer.current == ExpressionLexer::COLON
        lexer.advance
        argc = parse_filter_args(lexer)
      end

      # Apply filter aliases at compile time (lowering)
      filter_name = FILTER_ALIASES.fetch(filter_name, filter_name)
      @builder.call_filter(filter_name, argc)
    end

    def parse_filter_args(lexer)
      argc = 0

      loop do
        # Check for keyword argument
        if lexer.current == ExpressionLexer::IDENTIFIER
          # Look ahead for colon
          saved_pos = lexer.instance_variable_get(:@scanner).pos
          saved_value = lexer.value
          lexer.advance

          if lexer.current == ExpressionLexer::COLON
            # This is a keyword argument - emit key then value
            lexer.advance
            key = saved_value
            @builder.const_string(key)
            parse_expression(lexer)
            argc += 2
          else
            # Not a keyword arg, restore and parse as positional
            lexer.instance_variable_get(:@scanner).pos = saved_pos
            lexer.instance_variable_set(:@current_token, ExpressionLexer::IDENTIFIER)
            lexer.instance_variable_set(:@current_value, saved_value)
            lexer.instance_variable_set(:@peeked, true)
            parse_expression(lexer)
            argc += 1
          end
        else
          parse_expression(lexer)
          argc += 1
        end

        break unless lexer.current == ExpressionLexer::COMMA

        lexer.advance
      end

      argc
    end

    # --- Tag implementations ---

    def parse_if_tag(condition_str)
      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label
      label_end = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_false(label_else)

      branch_blanks = []
      branch_raws = []

      # Parse body until elsif/else/endif
      end_tag, body_blank, body_raws = parse_block_body(%w[elsif else endif])
      branch_blanks << body_blank
      branch_raws << body_raws

      case end_tag
      when 'elsif'
        @builder.jump(label_end)
        @builder.label(label_else)
        elsif_blanks, elsif_raws = parse_elsif_chain(label_end)
        branch_blanks.concat(elsif_blanks)
        branch_raws.concat(elsif_raws)
      when 'else'
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endif])
        branch_blanks << else_blank
        branch_raws << else_raws
        advance_template # consume endif
      when 'endif'
        @builder.label(label_else)
        advance_template
      end

      @builder.label(label_end)
      tag_blank = branch_blanks.all?
      branch_raws.each { |indices| strip_blank_raws(indices) } if tag_blank
      tag_blank
    end

    def parse_elsif_chain(label_end)
      branch_blanks = []
      branch_raws = []

      content = current_template_content
      parts = content.split(/\s+/, 2)
      condition_str = parts[1] || ''

      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_false(label_else)

      advance_template
      end_tag, body_blank, body_raws = parse_block_body(%w[elsif else endif])
      branch_blanks << body_blank
      branch_raws << body_raws

      case end_tag
      when 'elsif'
        @builder.jump(label_end)
        @builder.label(label_else)
        nested_blanks, nested_raws = parse_elsif_chain(label_end)
        branch_blanks.concat(nested_blanks)
        branch_raws.concat(nested_raws)
      when 'else'
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endif])
        branch_blanks << else_blank
        branch_raws << else_raws
        advance_template
      when 'endif'
        @builder.label(label_else)
        advance_template
      end

      [branch_blanks, branch_raws]
    end

    def parse_unless_tag(condition_str)
      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label
      label_end = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_true(label_else) # NOTE: opposite of if

      branch_blanks = []
      branch_raws = []

      end_tag, body_blank, body_raws = parse_block_body(%w[elsif else endunless])
      branch_blanks << body_blank
      branch_raws << body_raws

      case end_tag
      when 'elsif'
        @builder.jump(label_end)
        @builder.label(label_else)
        elsif_blanks, elsif_raws = parse_elsif_chain_unless(label_end)
        branch_blanks.concat(elsif_blanks)
        branch_raws.concat(elsif_raws)
      when 'else'
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endunless])
        branch_blanks << else_blank
        branch_raws << else_raws
        advance_template
      when 'endunless'
        @builder.label(label_else)
        advance_template
      end

      @builder.label(label_end)
      tag_blank = branch_blanks.all?
      branch_raws.each { |indices| strip_blank_raws(indices) } if tag_blank
      tag_blank
    end

    def parse_elsif_chain_unless(label_end)
      branch_blanks = []
      branch_raws = []

      content = current_template_content
      parts = content.split(/\s+/, 2)
      condition_str = parts[1] || ''

      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_false(label_else)

      advance_template
      end_tag, body_blank, body_raws = parse_block_body(%w[elsif else endunless])
      branch_blanks << body_blank
      branch_raws << body_raws

      case end_tag
      when 'elsif'
        @builder.jump(label_end)
        @builder.label(label_else)
        nested_blanks, nested_raws = parse_elsif_chain_unless(label_end)
        branch_blanks.concat(nested_blanks)
        branch_raws.concat(nested_raws)
      when 'else'
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endunless])
        branch_blanks << else_blank
        branch_raws << else_raws
        advance_template
      when 'endunless'
        @builder.label(label_else)
        advance_template
      end

      [branch_blanks, branch_raws]
    end

    def parse_case_tag(case_expr_str)
      begin
        expr_lexer = ExpressionLexer.new(case_expr_str)
        expr_lexer.advance
        parse_expression(expr_lexer)

        @builder.store_temp(0) # Store case value
      rescue SyntaxError
        # Invalid case expression - skip the entire case block without emitting IL
        skip_to_end_tag('endcase')
        return true # Tag is blank since nothing renders
      end

      label_end = @builder.new_label
      branch_blanks = []
      branch_raws = []

      # Parse until first when or else
      end_tag, body_blank, body_raws = parse_block_body(%w[when else endcase])
      branch_blanks << body_blank
      branch_raws << body_raws

      while end_tag == 'when'
        end_tag, when_blank, when_raws = parse_when_clause(label_end)
        branch_blanks << when_blank
        branch_raws << when_raws
      end

      if end_tag == 'else'
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endcase])
        branch_blanks << else_blank
        branch_raws << else_raws
        advance_template
      elsif end_tag == 'endcase'
        advance_template
      end

      @builder.label(label_end)
      tag_blank = branch_blanks.all?
      branch_raws.each { |indices| strip_blank_raws(indices) } if tag_blank
      tag_blank
    end

    def parse_when_clause(label_end)
      content = current_template_content
      parts = content.split(/\s+/, 2)
      when_values_str = parts[1] || ''

      # Parse comma-separated values
      label_body = @builder.new_label
      label_next = @builder.new_label

      # Split on commas or "or" and check each value
      when_values_str.split(/\s*(?:,|\bor\b)\s*/).each do |val_str|
        val_str = val_str.strip
        next if val_str.empty?

        begin
          expr_lexer = ExpressionLexer.new(val_str)
          expr_lexer.advance

          @builder.load_temp(0)
          parse_expression(expr_lexer)
          @builder.compare(:eq)
          @builder.jump_if_true(label_body)
        rescue SyntaxError
          # Skip invalid when expressions
          next
        end
      end

      @builder.jump(label_next)
      @builder.label(label_body)

      advance_template
      end_tag, body_blank, body_raws = parse_block_body(%w[when else endcase])

      @builder.jump(label_end)
      @builder.label(label_next)

      [end_tag, body_blank, body_raws]
    end

    def parse_for_tag(tag_args)
      # Parse: var_name in collection [limit:N] [offset:N] [reversed]
      match = tag_args.match(/(\w+)\s+in\s+(.+)/)
      raise SyntaxError, 'Invalid for tag syntax' unless match

      var_name = match[1]
      rest = match[2]

      # Parse options
      limit_expr = nil
      offset_expr = nil
      offset_continue = false
      reversed = false

      # Check for reversed
      if rest =~ /\breversed\b/
        reversed = true
        rest = rest.gsub(/\breversed\b/, '')
      end

      # Check for limit
      if rest =~ /\blimit\s*:\s*([^,\s]+)/
        limit_expr = Regexp.last_match(1)
        rest = rest.gsub(/\blimit\s*:\s*[^,\s]+/, '')
      end

      # Check for offset
      if rest =~ /\boffset\s*:\s*continue\b/
        offset_continue = true
        rest = rest.gsub(/\boffset\s*:\s*continue\b/, '')
      end
      if rest =~ /\boffset\s*:\s*([^,\s]+)/
        offset_expr = Regexp.last_match(1)
        offset_continue = false
        rest = rest.gsub(/\boffset\s*:\s*[^,\s]+/, '')
      end

      collection_expr = rest.tr(',', ' ').strip

      # Generate loop name for offset:continue
      loop_name = "#{var_name}-#{collection_expr}"

      # Labels
      label_loop = @builder.new_label
      label_continue = @builder.new_label
      label_break = @builder.new_label
      label_else = @builder.new_label
      label_end = @builder.new_label

      # Evaluate collection
      expr_lexer = ExpressionLexer.new(collection_expr)
      expr_lexer.advance
      parse_expression(expr_lexer)

      # Check for empty BEFORE initializing iterator - jump_if_empty peeks then pops if empty
      @builder.jump_if_empty(label_else)

      if limit_expr
        limit_lexer = ExpressionLexer.new(limit_expr)
        limit_lexer.advance
        parse_expression(limit_lexer)
      end

      if offset_expr
        offset_lexer = ExpressionLexer.new(offset_expr)
        offset_lexer.advance
        parse_expression(offset_lexer)
      end

      # Initialize for loop (pops collection, creates iterator)
      @builder.for_init(var_name, loop_name, !limit_expr.nil?, !offset_expr.nil?, offset_continue, reversed)

      @builder.push_scope
      @builder.push_forloop

      @builder.label(label_loop)
      @builder.for_next(label_continue, label_break)
      @builder.assign(var_name)

      # Render body
      @loop_stack.push({ break: label_break, continue: label_continue })
      end_tag, body_blank, body_raws = parse_block_body(%w[else endfor])
      @loop_stack.pop

      # Check for interrupts
      @builder.jump_if_interrupt(label_break)

      @builder.label(label_continue)
      @builder.pop_interrupt
      @builder.jump(label_loop)

      @builder.label(label_break)
      @builder.pop_interrupt
      @builder.pop_forloop
      @builder.pop_scope
      @builder.for_end
      @builder.jump(label_end)

      @builder.label(label_else)
      else_blank = true
      else_raws = nil
      if end_tag == 'else'
        advance_template
        _end_tag, else_blank, else_raws = parse_block_body(%w[endfor])
      end

      @builder.label(label_end)
      advance_template # consume endfor

      tag_blank = body_blank && (end_tag != 'else' || else_blank)
      if tag_blank
        strip_blank_raws(body_raws)
        strip_blank_raws(else_raws) if end_tag == 'else'
      end
      tag_blank
    end

    def parse_tablerow_tag(tag_args)
      # Parse: var_name in collection [cols:N] [limit:N] [offset:N]
      match = tag_args.match(/(\w+)\s+in\s+(.+)/)
      raise SyntaxError, 'Invalid tablerow tag syntax' unless match

      var_name = match[1]
      rest = match[2]

      # Parse options
      limit_expr = nil
      offset_expr = nil
      cols = nil # default: all in one row

      # Check for cols
      if rest =~ /\bcols\s*:\s*(\d+)/
        cols = Regexp.last_match(1).to_i
        rest = rest.gsub(/\bcols\s*:\s*\d+/, '')
      end

      # Check for limit
      if rest =~ /\blimit\s*:\s*([^,\s]+)/
        limit_expr = Regexp.last_match(1)
        rest = rest.gsub(/\blimit\s*:\s*[^,\s]+/, '')
      end

      # Check for offset
      if rest =~ /\boffset\s*:\s*([^,\s]+)/
        offset_expr = Regexp.last_match(1)
        rest = rest.gsub(/\boffset\s*:\s*[^,\s]+/, '')
      end

      collection_expr = rest.tr(',', ' ').strip

      # Generate loop name
      loop_name = "#{var_name}-#{collection_expr}"

      # Labels
      label_loop = @builder.new_label
      label_continue = @builder.new_label
      label_break = @builder.new_label
      label_else = @builder.new_label
      label_end = @builder.new_label

      # Evaluate collection
      expr_lexer = ExpressionLexer.new(collection_expr)
      expr_lexer.advance
      parse_expression(expr_lexer)

      # Check for empty
      @builder.jump_if_empty(label_else)

      if limit_expr
        limit_lexer = ExpressionLexer.new(limit_expr)
        limit_lexer.advance
        parse_expression(limit_lexer)
      end

      if offset_expr
        offset_lexer = ExpressionLexer.new(offset_expr)
        offset_lexer.advance
        parse_expression(offset_lexer)
      end

      # Initialize tablerow (pops collection, creates iterator with cols)
      @builder.tablerow_init(var_name, loop_name, !limit_expr.nil?, !offset_expr.nil?, cols)

      @builder.push_scope
      @builder.push_forloop

      @builder.label(label_loop)
      @builder.tablerow_next(label_continue, label_break)
      @builder.assign(var_name)

      # Render body
      @loop_stack.push({ break: label_break, continue: label_continue })
      _, body_blank, = parse_block_body(%w[endtablerow])
      @loop_stack.pop

      # Check for interrupts
      @builder.jump_if_interrupt(label_break)

      @builder.label(label_continue)
      @builder.pop_interrupt
      @builder.jump(label_loop)

      @builder.label(label_break)
      @builder.pop_interrupt
      @builder.pop_forloop
      @builder.pop_scope
      @builder.tablerow_end

      @builder.label(label_else)
      @builder.label(label_end)
      advance_template # consume endtablerow

      body_blank
    end

    def parse_assign_tag(tag_args)
      match = tag_args.match(/([\w-]+)\s*=\s*(.+)/)
      raise SyntaxError, 'Invalid assign syntax' unless match

      var_name = match[1]
      value_expr = match[2]

      expr_lexer = ExpressionLexer.new(value_expr)
      expr_lexer.advance
      parse_expression(expr_lexer)
      parse_filters(expr_lexer)

      @builder.assign(var_name)
      true
    end

    def parse_capture_tag(tag_args)
      lexer = ExpressionLexer.new(tag_args)
      lexer.advance

      # Variable name can be identifier or quoted string
      var_name = case lexer.current
                 when ExpressionLexer::IDENTIFIER
                   lexer.value
                 when ExpressionLexer::STRING
                   lexer.value
                 else
                   raise SyntaxError, 'Capture requires variable name'
                 end

      @builder.push_capture

      _end_tag, _body_blank, _body_raws = parse_block_body(%w[endcapture])
      advance_template

      @builder.pop_capture
      @builder.assign(var_name)
      true
    end

    def parse_increment_tag(tag_args)
      var_name = tag_args.strip
      @builder.increment(var_name)
      @builder.write_value
      false
    end

    def parse_decrement_tag(tag_args)
      var_name = tag_args.strip
      @builder.decrement(var_name)
      @builder.write_value
      false
    end

    def parse_cycle_tag(tag_args)
      # Parse: 'group': val1, val2, val3  OR  identifier: val1, val2  OR  val1, val2, val3
      # Values can be literals (strings, numbers) or variables (identifiers)
      expr_lexer = ExpressionLexer.new(tag_args)
      expr_lexer.advance

      group = nil
      group_var = nil # Variable name to lookup for group

      # Check if first element is a group name (followed by :)
      first_value = nil
      first_is_var = false
      case expr_lexer.current
      when ExpressionLexer::STRING
        first_value = [:lit, expr_lexer.value]
        expr_lexer.advance
        # Check for colon - string group name
        if expr_lexer.current == ExpressionLexer::COLON
          group = first_value[1]
          first_value = nil
          expr_lexer.advance
        end
      when ExpressionLexer::NUMBER
        val = expr_lexer.value
        num_val = val.include?('.') ? val.to_f : val.to_i
        first_value = [:lit, num_val]
        expr_lexer.advance
        # Check for colon - numeric group name
        if expr_lexer.current == ExpressionLexer::COLON
          group = val.to_s # Group name as string
          first_value = nil
          expr_lexer.advance
        end
      when ExpressionLexer::IDENTIFIER
        first_value = [:var, expr_lexer.value]
        first_is_var = true
        expr_lexer.advance
        # Check for colon - variable group name
        if expr_lexer.current == ExpressionLexer::COLON
          group_var = first_value[1]
          first_value = nil
          expr_lexer.advance
        end
      end

      # Parse values - each is tagged as [:lit, value] or [:var, name]
      values = []
      if first_value
        values << first_value
      end

      loop do
        case expr_lexer.current
        when ExpressionLexer::STRING
          values << [:lit, expr_lexer.value]
          expr_lexer.advance
        when ExpressionLexer::NUMBER
          val = expr_lexer.value
          values << [:lit, val.include?('.') ? val.to_f : val.to_i]
          expr_lexer.advance
        when ExpressionLexer::IDENTIFIER
          values << [:var, expr_lexer.value]
          expr_lexer.advance
        when ExpressionLexer::EOF
          break
        when ExpressionLexer::COMMA
          expr_lexer.advance
        else
          expr_lexer.advance
        end
      end

      # Check if any values are variables (need runtime lookup)
      has_var_values = values.any? { |v| v[0] == :var }

      # Build identity from original values (variable names stay as-is, not resolved)
      identity_parts = values.map { |v| v[1].to_s }
      base_identity = identity_parts.join(',')

      # When there are variable lookups and no explicit group, add unique counter
      # This ensures identical cycle tags at different positions have separate counters
      if has_var_values && !group && !group_var
        @cycle_counter += 1
        default_identity = "#{base_identity}##{@cycle_counter}"
      else
        default_identity = base_identity
      end

      if group_var
        # Need runtime lookup for group - use CYCLE_STEP_VAR
        @builder.cycle_step_var(group_var, values)
      else
        identity = group || default_identity
        @builder.cycle_step(identity, values)
      end
      @builder.write_value
      false
    end

    def parse_echo_tag(tag_args)
      expr_lexer = ExpressionLexer.new(tag_args)
      expr_lexer.advance
      parse_expression(expr_lexer)
      parse_filters(expr_lexer)
      @builder.write_value
      false
    end

    def parse_liquid_tag(content)
      # The liquid tag contains multiple statements, one per line
      lines = content.split("\n")
      blank = true
      lines.each do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        # Parse each line as a tag without delimiters
        parts = line.split(/\s+/, 2)
        tag_name = parts[0]
        tag_args = parts[1] || ''

        case tag_name
        when 'echo'
          blank &&= parse_echo_tag(tag_args)
        when 'assign'
          blank &&= parse_assign_tag(tag_args)
        when 'if'
          # For liquid tag, we need to handle block tags differently
          # This is simplified - full implementation would track nested blocks
          parse_simple_if_in_liquid(tag_args, lines)
          blank = false
        when 'break'
          emit_loop_jump(:break)
          blank = false
        when 'continue'
          emit_loop_jump(:continue)
          blank = false
        when 'increment'
          parse_increment_tag(tag_args)
          blank = false
        when 'decrement'
          parse_decrement_tag(tag_args)
          blank = false
        when 'cycle'
          parse_cycle_tag(tag_args)
          blank = false
        end
      end
      blank
    end

    def parse_simple_if_in_liquid(condition, _lines)
      # Simplified - just evaluates condition
      expr_lexer = ExpressionLexer.new(condition)
      expr_lexer.advance
      parse_expression(expr_lexer)
      @builder.is_truthy
      # Would need to handle the block structure...
      false
    end

    def parse_raw_tag
      # Raw content is output verbatim - trim markers on raw/endraw
      # only affect the TEMPLATE content before/after, not the raw content itself

      # Use lexer's raw mode to scan until {% endraw %} without tokenizing
      result = @template_lexer.scan_raw_body

      if result
        content, _endraw_trim_left, _endraw_trim_right = result

        # Output raw content as-is (no trimming)
        @builder.write_raw(content) unless content.empty?

        # The lexer has already consumed endraw, so just advance to next token
        advance_template
        content.empty?
      else
        # No endraw found - emit remaining content as-is
        @builder.write_raw('')
        true
      end
    end

    def parse_comment_tag
      # Skip until endcomment, but track raw and comment nesting
      raw_depth = 0
      comment_depth = 0 # Track nested comments
      until template_eos?
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          case tag_name
          when 'raw'
            raw_depth += 1
          when 'endraw'
            raw_depth -= 1 if raw_depth > 0
          when 'comment'
            comment_depth += 1 if raw_depth == 0
          when 'endcomment'
            if raw_depth == 0
              if comment_depth > 0
                comment_depth -= 1
              else
                advance_template
                break
              end
            end
          end
        end
        advance_template
      end
      true
    end

    def parse_doc_tag
      # Skip until enddoc - doc ignores everything inside including malformed tags
      has_content = false
      until template_eos?
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          if tag_name == 'enddoc'
            advance_template
            break
          end
        end
        has_content ||= !current_template_content.to_s.empty?
        advance_template
      end
      !has_content
    end

    def parse_render_tag(tag_args)
      # Parse: 'partial_name' [with expr | for expr] [as alias] [, var1: val1]
      lexer = ExpressionLexer.new(tag_args)
      lexer.advance

      # Get partial name (must be quoted string)
      raise SyntaxError, 'Render requires quoted partial name' unless lexer.current == ExpressionLexer::STRING

      partial_name = lexer.value
      lexer.advance

      args = {}
      with_expr = nil
      for_expr = nil
      as_alias = nil

      # Parse optional with/for/as and keyword args
      loop do
        case lexer.current
        when ExpressionLexer::IDENTIFIER
          keyword = lexer.value
          case keyword
          when 'with'
            lexer.advance
            with_expr = extract_expression_string(lexer)
          when 'for'
            lexer.advance
            for_expr = extract_expression_string(lexer)
          when 'as'
            lexer.advance
            if lexer.current == ExpressionLexer::IDENTIFIER
              as_alias = lexer.value
              lexer.advance
            end
          else
            # Could be keyword arg: key: value
            key = lexer.value
            lexer.advance
            if lexer.current == ExpressionLexer::COLON
              lexer.advance
              args[key] = extract_arg_value(lexer)
            end
          end
        when ExpressionLexer::COMMA
          lexer.advance
        when ExpressionLexer::EOF
          break
        else
          lexer.advance # Skip unexpected tokens
        end
      end

      args['__with__'] = with_expr if with_expr
      args['__for__'] = for_expr if for_expr
      args['__as__'] = as_alias if as_alias

      @builder.render_partial(partial_name, args)
      false
    end

    # Extract an expression as a string for runtime evaluation
    def extract_expression_string(lexer)
      parts = []
      paren_depth = 0

      loop do
        case lexer.current
        when ExpressionLexer::EOF
          break
        when ExpressionLexer::COMMA
          break if paren_depth == 0

          parts << ','
          lexer.advance
        when ExpressionLexer::IDENTIFIER
          # Check for keywords that end expressions
          break if paren_depth == 0 && %w[as with for].include?(lexer.value)

          parts << lexer.value
          lexer.advance
        when ExpressionLexer::LPAREN
          paren_depth += 1
          parts << '('
          lexer.advance
        when ExpressionLexer::RPAREN
          paren_depth -= 1
          parts << ')'
          lexer.advance
        when ExpressionLexer::DOTDOT
          parts << '..'
          lexer.advance
        when ExpressionLexer::DOT
          parts << '.'
          lexer.advance
        when ExpressionLexer::LBRACKET
          parts << '['
          lexer.advance
        when ExpressionLexer::RBRACKET
          parts << ']'
          lexer.advance
        when ExpressionLexer::NUMBER
          parts << lexer.value
          lexer.advance
        when ExpressionLexer::STRING
          parts << "'#{lexer.value}'"
          lexer.advance
        when ExpressionLexer::COLON
          # If we see a colon after identifier, this might be a keyword arg
          break if paren_depth == 0

          parts << ':'
          lexer.advance
        else
          lexer.advance
        end
      end

      parts.join
    end

    # Extract argument value for keyword args
    def extract_arg_value(lexer)
      case lexer.current
      when ExpressionLexer::STRING
        val = lexer.value
        lexer.advance
        val
      when ExpressionLexer::NUMBER
        val = lexer.value
        lexer.advance
        val.include?('.') ? val.to_f : val.to_i
      when ExpressionLexer::TRUE
        lexer.advance
        true
      when ExpressionLexer::FALSE
        lexer.advance
        false
      when ExpressionLexer::NIL
        lexer.advance
        nil
      when ExpressionLexer::IDENTIFIER
        var = lexer.value
        lexer.advance
        # Check for property chain
        expr = var
        while [ExpressionLexer::DOT, ExpressionLexer::LBRACKET].include?(lexer.current)
          if lexer.current == ExpressionLexer::DOT
            lexer.advance
            expr += ".#{lexer.value}" if lexer.current == ExpressionLexer::IDENTIFIER
            lexer.advance
          elsif lexer.current == ExpressionLexer::LBRACKET
            expr += '['
            lexer.advance
            if lexer.current == ExpressionLexer::NUMBER
              expr += lexer.value
              lexer.advance
            elsif lexer.current == ExpressionLexer::STRING
              expr += "'#{lexer.value}'"
              lexer.advance
            end
            expr += ']' if lexer.current == ExpressionLexer::RBRACKET
            lexer.advance if lexer.current == ExpressionLexer::RBRACKET
          end
        end
        { __var__: expr }
      else
        lexer.advance
        nil
      end
    end

    def parse_include_tag(tag_args)
      # Similar to render but with shared context
      # Support both quoted strings and variable references
      quoted_match = tag_args.match(/\A\s*(['"])(.+?)\1(.*)/)
      var_match = tag_args.match(/\A\s*(\w+)(.*)/) unless quoted_match

      if quoted_match
        partial_name = quoted_match[2]
        rest = quoted_match[3].strip
        dynamic_name = false
      elsif var_match
        partial_name = var_match[1]
        rest = var_match[2].strip
        dynamic_name = true
      else
        return # Invalid syntax
      end

      args = {}
      with_var = nil
      for_collection = nil
      as_alias = nil

      # Parse "with expression" - support complex expressions like products[0]
      if rest =~ /\bwith\s+([\w\[\].]+)/
        with_var = Regexp.last_match(1)
        rest = rest.gsub(/\bwith\s+[\w\[\].]+/, '')
      end

      # Parse "for expression"
      if rest =~ /\bfor\s+([\w\[\].]+)/
        for_collection = Regexp.last_match(1)
        rest = rest.gsub(/\bfor\s+[\w\[\].]+/, '')
      end

      # Parse "as alias" - must come after with/for
      if rest =~ /\bas\s+(\w+)/
        as_alias = Regexp.last_match(1)
        rest = rest.gsub(/\bas\s+\w+/, '')
      end

      # Parse keyword args - handle literals and complex expressions
      rest.scan(/([\w-]+)\s*:\s*(?:(['"])(.+?)\2|(-?\d+(?:\.\d+)?)|([\w.\[\]]+))/) do
        key = Regexp.last_match(1)
        if Regexp.last_match(3)       # String literal
          args[key] = Regexp.last_match(3)
        elsif Regexp.last_match(4)    # Number
          num = Regexp.last_match(4)
          args[key] = num.include?('.') ? num.to_f : num.to_i
        elsif Regexp.last_match(5)    # Expression - look up at runtime
          args[key] = { __var__: Regexp.last_match(5) }
        end
      end

      args['__with__'] = with_var if with_var
      args['__for__'] = for_collection if for_collection
      args['__as__'] = as_alias if as_alias
      args['__dynamic_name__'] = partial_name if dynamic_name

      @builder.include_partial(partial_name, args)
      false
    end

    def expect_eos(lexer)
      return if lexer.eos?

      raise SyntaxError, "Unexpected token #{lexer.current} after expression"
    end
  end
end
