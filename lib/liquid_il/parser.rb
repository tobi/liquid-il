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
      @pending_trim_left = false # When true, next RAW should have leading whitespace trimmed
    end

    def parse
      @template_lexer.reset
      advance_template
      parse_block_body(nil)
      @builder.halt
      @builder.instructions
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
            @pending_trim_left = current_template_trim_right  # For next RAW token
            parse_variable_output
            blank = false
          when TemplateLexer::TAG
            trim_previous_raw if current_template_trim_left
            @pending_trim_left = current_template_trim_right  # For next RAW token
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
      # Apply pending trim if previous element had trim_right
      if @pending_trim_left
        content = content.lstrip
        @pending_trim_left = false
      end
      emit_raw(content) unless content.empty?
      advance_template
      content.empty? || content.match?(WHITESPACE_ONLY)
    end

    def parse_variable_output
      content = current_template_content
      @builder.with_span(current_template_start_pos, current_template_end_pos)

      # Handle empty variable `{{}}`
      if content.strip.empty?
        @builder.clear_span
        advance_template
        return true  # Blank output
      end

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
      when 'ifchanged'
        advance_template
        parse_ifchanged_tag
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
      # Always use PUSH_INTERRUPT, let JUMP_IF_INTERRUPT handle the actual jump
      # This ensures any cleanup code (like POP_CAPTURE) runs before the jump
      @builder.push_interrupt(type)
    end

    # --- Expression parsing ---

    def parse_expression(lexer)
      parse_logical_expression(lexer)
    end

    # Liquid uses RIGHT-ASSOCIATIVE evaluation with equal precedence for and/or
    # So `a and b or c` = `a and (b or c)` and `a or b and c` = `a or (b and c)`
    def parse_logical_expression(lexer)
      parse_comparison_expression(lexer)

      if lexer.current == ExpressionLexer::AND
        lexer.advance
        label_false = @builder.new_label
        label_end = @builder.new_label

        @builder.jump_if_false(label_false)
        parse_logical_expression(lexer)  # Right-recursive for right operand
        @builder.jump(label_end)
        @builder.label(label_false)
        @builder.const_false
        @builder.label(label_end)
      elsif lexer.current == ExpressionLexer::OR
        lexer.advance
        label_true = @builder.new_label
        label_end = @builder.new_label

        @builder.jump_if_true(label_true)
        parse_logical_expression(lexer)  # Right-recursive for right operand
        @builder.jump(label_end)
        @builder.label(label_true)
        @builder.const_true
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
      pos_args_count = 0
      kw_args_builders = []

      loop do
        # Check for keyword argument
        if lexer.current == ExpressionLexer::IDENTIFIER
          # Look ahead for colon
          saved_state = lexer.save_state
          lexer.advance

          if lexer.current == ExpressionLexer::COLON
            # This is a keyword argument
            lexer.advance
            key = saved_state[:value]
            
            # Use a temporary builder to capture instructions for keyword args
            kw_builder = IL::Builder.new
            # Set the current span on the kw_builder so keyword arg instructions have it
            kw_builder.with_span(*@builder.instance_variable_get(:@current_span)) if @builder.instance_variable_get(:@current_span)
            
            original_builder = @builder
            @builder = kw_builder
            @builder.const_string(key)
            parse_expression(lexer)
            @builder = original_builder
            kw_args_builders << kw_builder
          else
            # Not a keyword arg, restore and parse as positional
            lexer.restore_state(saved_state)
            parse_expression(lexer)
            pos_args_count += 1
          end
        else
          parse_expression(lexer)
          pos_args_count += 1
        end

        break unless lexer.current == ExpressionLexer::COMMA

        lexer.advance
      end

      # Now emit all keyword arguments
      kw_args_builders.each do |builder|
        @builder.emit_from(builder)
      end

      if kw_args_builders.any?
        @builder.build_hash(kw_args_builders.length)
        pos_args_count + 1
      else
        pos_args_count
      end
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
        # Stop at elsif/else/endif - any elsif/else after else is malformed but ignored
        end_tag, else_blank, else_raws = parse_block_body(%w[elsif else endif])
        branch_blanks << else_blank
        branch_raws << else_raws
        # Skip any remaining elsif/else until endif (discard their content)
        while end_tag == 'elsif' || end_tag == 'else'
          advance_template
          @builder.push_capture  # Capture to discard
          end_tag, _, _ = parse_block_body(%w[elsif else endif])
          @builder.pop_capture
          @builder.pop  # Discard captured content
        end
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
      # Allocate unique temp indices for this case statement (supports nesting)
      @case_temp_counter ||= 0
      case_value_temp = @case_temp_counter
      case_flag_temp = @case_temp_counter + 1
      @case_temp_counter += 2

      begin
        expr_lexer = ExpressionLexer.new(case_expr_str)
        expr_lexer.advance
        parse_expression(expr_lexer)

        @builder.store_temp(case_value_temp) # Store case value
      rescue SyntaxError
        # Invalid case expression - skip the entire case block without emitting IL
        @case_temp_counter -= 2  # Release temp indices
        skip_to_end_tag('endcase')
        return true # Tag is blank since nothing renders
      end

      # Initialize "any_when_matched" flag to false
      @builder.const_false
      @builder.store_temp(case_flag_temp)

      branch_blanks = []
      branch_raws = []

      # Parse until first when or else - discard this content (between case and first when)
      # In Liquid, this content is ignored
      @builder.push_capture
      end_tag, body_blank, body_raws = parse_block_body(%w[when else endcase])
      @builder.pop_capture  # Discard captured content
      @builder.pop  # Pop and discard the captured string from stack
      # Don't track this for blank detection - it's always discarded

      # Process interspersed when/else clauses
      while end_tag == 'when' || end_tag == 'else'
        if end_tag == 'when'
          end_tag, when_blank, when_raws = parse_when_clause_with_flag(case_value_temp, case_flag_temp)
          branch_blanks << when_blank
          branch_raws << when_raws
        else  # else
          end_tag, else_blank, else_raws = parse_else_clause_with_flag(case_flag_temp)
          branch_blanks << else_blank
          branch_raws << else_raws
        end
      end

      if end_tag == 'endcase'
        advance_template
      end

      @case_temp_counter -= 2  # Release temp indices

      tag_blank = branch_blanks.all?
      branch_raws.each { |indices| strip_blank_raws(indices) } if tag_blank
      tag_blank
    end

    def parse_when_clause_with_flag(case_value_temp, case_flag_temp)
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

          @builder.load_temp(case_value_temp)   # Load case value
          parse_expression(expr_lexer)          # Push when value
          @builder.case_compare                 # Case-specific compare
          @builder.jump_if_true(label_body)
        rescue SyntaxError
          # Skip invalid when expressions
          next
        end
      end

      @builder.jump(label_next)
      @builder.label(label_body)

      # Set the "any_when_matched" flag to true
      @builder.const_true
      @builder.store_temp(case_flag_temp)

      advance_template
      end_tag, body_blank, body_raws = parse_block_body(%w[when else endcase])

      @builder.label(label_next)

      [end_tag, body_blank, body_raws]
    end

    def parse_else_clause_with_flag(case_flag_temp)
      # Only execute else body if no when has matched yet
      label_skip = @builder.new_label
      label_end = @builder.new_label

      @builder.load_temp(case_flag_temp)  # Load "any_when_matched" flag
      @builder.jump_if_true(label_skip)  # Skip else if any when matched

      advance_template
      end_tag, body_blank, body_raws = parse_block_body(%w[when else endcase])

      @builder.jump(label_end)
      @builder.label(label_skip)

      # Still need to parse and skip the else body content
      # But we already parsed it above, so just continue
      @builder.label(label_end)

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

      # Emit offset first, then limit (IL order matches application order)
      # Sequential readers can apply: offset first (drop N), then limit (take M)
      if offset_expr
        offset_lexer = ExpressionLexer.new(offset_expr)
        offset_lexer.advance
        parse_expression(offset_lexer)
      end

      if limit_expr
        limit_lexer = ExpressionLexer.new(limit_expr)
        limit_lexer.advance
        parse_expression(limit_lexer)
      end

      # Initialize for loop (pops collection, creates iterator)
      # Pass label_end for error recovery - on error, output error message and jump past the for block
      @builder.for_init(var_name, loop_name, !limit_expr.nil?, !offset_expr.nil?, offset_continue, reversed, label_end)

      @builder.push_scope
      @builder.push_forloop

      @builder.label(label_loop)
      @builder.for_next(label_continue, label_break)
      @builder.assign_local(var_name)

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
      cols_expr = nil # expression for cols (if variable)

      # Check for cols (handle numeric, nil, and variable cases)
      if rest =~ /\bcols\s*:\s*nil\b/i
        cols = :explicit_nil  # Explicitly set to nil - col_last is always false
        rest = rest.gsub(/\bcols\s*:\s*nil\b/i, '')
      elsif rest =~ /\bcols\s*:\s*(\d+)/
        cols = Regexp.last_match(1).to_i
        rest = rest.gsub(/\bcols\s*:\s*\d+/, '')
      elsif rest =~ /\bcols\s*:\s*([a-zA-Z_][a-zA-Z0-9_.\[\]'"]*)/
        cols_expr = Regexp.last_match(1)
        rest = rest.gsub(/\bcols\s*:\s*[a-zA-Z_][a-zA-Z0-9_.\[\]'"]*/, '')
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

      # Note: Unlike for loops, tablerow should NOT jump_if_empty
      # because even empty tablerows output <tr class="row1"></tr>

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

      # Handle dynamic cols expression
      if cols_expr
        cols_lexer = ExpressionLexer.new(cols_expr)
        cols_lexer.advance
        parse_expression(cols_lexer)
        cols = :dynamic  # Signal that cols value is on the stack
      end

      # Initialize tablerow (pops collection, creates iterator with cols)
      @builder.tablerow_init(var_name, loop_name, !limit_expr.nil?, !offset_expr.nil?, cols)

      @builder.push_scope
      # NOTE: tablerow does NOT push a forloop - it has its own tablerowloop variable
      # forloop inside tablerow refers to the enclosing for loop (if any)

      @builder.label(label_loop)
      @builder.tablerow_next(label_continue, label_break)
      @builder.assign_local(var_name)

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

    def parse_ifchanged_tag
      # Generate unique tag ID based on position
      @ifchanged_counter ||= 0
      @ifchanged_counter += 1
      tag_id = "ifchanged_#{@ifchanged_counter}"

      # Capture the body content
      @builder.push_capture

      _end_tag, _body_blank, _body_raws = parse_block_body(%w[endifchanged])
      advance_template

      @builder.pop_capture
      @builder.ifchanged_check(tag_id)
      false
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
        # In cycle, .5 means "look up variable named 5", not float 0.5
        if val.start_with?('.')
          first_value = [:var, val[1..]]  # Strip leading dot, treat as variable
          first_is_var = true
        else
          num_val = val.include?('.') ? val.to_f : val.to_i
          first_value = [:lit, num_val]
        end
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
          # In cycle, .5 means "look up variable named 5", not float 0.5
          if val.start_with?('.')
            values << [:var, val[1..]]  # Strip leading dot, treat as variable
          else
            values << [:lit, val.include?('.') ? val.to_f : val.to_i]
          end
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
      idx = 0

      while idx < lines.length
        line = lines[idx].strip
        idx += 1
        next if line.empty? || line.start_with?('#')

        # Parse each line as a tag without delimiters
        parts = line.split(/\s+/, 2)
        tag_name = parts[0]
        tag_args = parts[1] || ''

        case tag_name
        when 'echo'
          result = parse_echo_tag(tag_args)
          blank = blank && result
        when 'assign'
          result = parse_assign_tag(tag_args)
          blank = blank && result
        when 'if'
          idx = parse_if_in_liquid(tag_args, lines, idx)
          blank = false
        when 'unless'
          idx = parse_unless_in_liquid(tag_args, lines, idx)
          blank = false
        when 'for'
          idx = parse_for_in_liquid(tag_args, lines, idx)
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
        when 'comment'
          # Skip all lines until endcomment
          idx = skip_comment_in_liquid(lines, idx)
        when 'capture'
          idx = parse_capture_in_liquid(tag_args, lines, idx)
          blank = false
        when 'liquid'
          # Nested liquid tag - recursively parse
          result = parse_liquid_tag(tag_args)
          blank = blank && result
        end
      end
      blank
    end

    # Skip lines within a liquid tag until endcomment
    def skip_comment_in_liquid(lines, idx)
      depth = 1
      while idx < lines.length && depth > 0
        line = lines[idx].strip
        idx += 1
        next if line.empty?

        parts = line.split(/\s+/, 2)
        tag_name = parts[0]

        case tag_name
        when 'comment'
          depth += 1
        when 'endcomment'
          depth -= 1
        end
      end
      idx
    end

    # Parse a capture block within a liquid tag
    def parse_capture_in_liquid(var_name_arg, lines, idx)
      # Extract variable name (can be identifier or quoted string)
      var_name = var_name_arg.strip
      if var_name.start_with?('"', "'")
        var_name = var_name[1..-2]  # Remove quotes
      end

      # Collect body lines until endcapture
      body_lines = []
      depth = 1
      comment_depth = 0

      while idx < lines.length && depth > 0
        line = lines[idx].strip
        idx += 1
        next if line.empty?

        parts = line.split(/\s+/, 2)
        tag_name = parts[0]

        # Track comment blocks
        if tag_name == 'comment'
          comment_depth += 1
          body_lines << line
          next
        elsif tag_name == 'endcomment'
          comment_depth -= 1 if comment_depth > 0
          body_lines << line
          next
        end

        # Skip depth tracking if inside comment
        if comment_depth > 0
          body_lines << line
          next
        end

        case tag_name
        when 'capture'
          depth += 1
          body_lines << line
        when 'endcapture'
          depth -= 1
          body_lines << line if depth > 0
        else
          body_lines << line
        end
      end

      # Generate capture code
      @builder.push_capture
      parse_liquid_tag(body_lines.join("\n")) unless body_lines.empty?
      @builder.pop_capture
      @builder.assign(var_name)

      idx
    end

    # Parse an if block within a liquid tag, returning the new line index
    def parse_if_in_liquid(condition, lines, idx)
      # Collect body lines until endif/else/elsif
      body_lines = []
      else_lines = []
      depth = 1
      comment_depth = 0
      in_else = false

      while idx < lines.length && depth > 0
        line = lines[idx].strip
        idx += 1
        next if line.empty?

        tag_name = line.split(/\s+/, 2)[0]

        # Track comment blocks
        if tag_name == 'comment'
          comment_depth += 1
          (in_else ? else_lines : body_lines) << line
          next
        elsif tag_name == 'endcomment'
          comment_depth -= 1 if comment_depth > 0
          (in_else ? else_lines : body_lines) << line
          next
        end

        # Skip other tag processing if inside comment
        if comment_depth > 0
          (in_else ? else_lines : body_lines) << line
          next
        end

        case tag_name
        when 'if', 'unless', 'for', 'case'
          depth += 1
          (in_else ? else_lines : body_lines) << line
        when 'endif', 'endunless', 'endfor', 'endcase'
          depth -= 1
          (in_else ? else_lines : body_lines) << line if depth > 0
        when 'else'
          if depth == 1
            in_else = true
          else
            (in_else ? else_lines : body_lines) << line
          end
        when 'elsif'
          # Treat elsif as end of this if + new if in else
          if depth == 1
            # This is a simplification - proper elsif handling would be more complex
            in_else = true
            else_lines << "if #{line.split(/\s+/, 2)[1]}"
          else
            (in_else ? else_lines : body_lines) << line
          end
        else
          (in_else ? else_lines : body_lines) << line
        end
      end

      # Generate if code
      label_else = @builder.new_label
      label_end = @builder.new_label

      expr_lexer = ExpressionLexer.new(condition)
      expr_lexer.advance
      parse_expression(expr_lexer)
      @builder.jump_if_false(label_else)

      parse_liquid_tag(body_lines.join("\n")) unless body_lines.empty?

      @builder.jump(label_end)
      @builder.label(label_else)

      parse_liquid_tag(else_lines.join("\n")) unless else_lines.empty?

      @builder.label(label_end)
      idx
    end

    # Parse an unless block within a liquid tag
    def parse_unless_in_liquid(condition, lines, idx)
      body_lines = []
      depth = 1

      while idx < lines.length && depth > 0
        line = lines[idx].strip
        idx += 1
        next if line.empty?

        tag_name = line.split(/\s+/, 2)[0]
        case tag_name
        when 'if', 'unless', 'for', 'case'
          depth += 1
          body_lines << line
        when 'endif', 'endunless', 'endfor', 'endcase'
          depth -= 1
          body_lines << line if depth > 0
        else
          body_lines << line
        end
      end

      label_end = @builder.new_label

      expr_lexer = ExpressionLexer.new(condition)
      expr_lexer.advance
      parse_expression(expr_lexer)
      @builder.jump_if_true(label_end)

      parse_liquid_tag(body_lines.join("\n")) unless body_lines.empty?

      @builder.label(label_end)
      idx
    end

    # Parse a for block within a liquid tag
    def parse_for_in_liquid(tag_args, lines, idx)
      # Collect body lines until endfor
      body_lines = []
      else_lines = []
      depth = 1
      in_else = false

      while idx < lines.length && depth > 0
        line = lines[idx].strip
        idx += 1
        next if line.empty?

        tag_name = line.split(/\s+/, 2)[0]
        case tag_name
        when 'if', 'unless', 'for', 'case', 'tablerow'
          depth += 1
          (in_else ? else_lines : body_lines) << line
        when 'endif', 'endunless', 'endfor', 'endcase', 'endtablerow'
          depth -= 1
          (in_else ? else_lines : body_lines) << line if depth > 0
        when 'else'
          if depth == 1
            in_else = true
          else
            (in_else ? else_lines : body_lines) << line
          end
        else
          (in_else ? else_lines : body_lines) << line
        end
      end

      # Parse for tag_args: var_name in collection [limit:N] [offset:N] [reversed]
      match = tag_args.match(/(\w+)\s+in\s+(.+)/)
      return idx unless match

      var_name = match[1]
      rest = match[2]

      limit_expr = nil
      offset_expr = nil
      offset_continue = false
      reversed = false

      if rest =~ /\breversed\b/
        reversed = true
        rest = rest.gsub(/\breversed\b/, '')
      end
      if rest =~ /\blimit\s*:\s*([^,\s]+)/
        limit_expr = Regexp.last_match(1)
        rest = rest.gsub(/\blimit\s*:\s*[^,\s]+/, '')
      end
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
      loop_name = "#{var_name}-#{collection_expr}"

      label_loop = @builder.new_label
      label_continue = @builder.new_label
      label_break = @builder.new_label
      label_else = @builder.new_label
      label_end = @builder.new_label

      # Evaluate collection
      expr_lexer = ExpressionLexer.new(collection_expr)
      expr_lexer.advance
      parse_expression(expr_lexer)

      @builder.jump_if_empty(label_else)

      # Emit offset first, then limit (IL order matches application order)
      # Sequential readers can apply: offset first (drop N), then limit (take M)
      if offset_expr
        offset_lexer = ExpressionLexer.new(offset_expr)
        offset_lexer.advance
        parse_expression(offset_lexer)
      end

      if limit_expr
        limit_lexer = ExpressionLexer.new(limit_expr)
        limit_lexer.advance
        parse_expression(limit_lexer)
      end

      @builder.for_init(var_name, loop_name, !limit_expr.nil?, !offset_expr.nil?, offset_continue, reversed, label_end)
      @builder.push_scope
      @builder.push_forloop

      @builder.label(label_loop)
      @builder.for_next(label_continue, label_break)
      @builder.assign_local(var_name)

      @loop_stack.push({ break: label_break, continue: label_continue })
      parse_liquid_tag(body_lines.join("\n")) unless body_lines.empty?
      @loop_stack.pop

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
      parse_liquid_tag(else_lines.join("\n")) unless else_lines.empty?

      @builder.label(label_end)
      idx
    end

    def parse_raw_tag
      # Raw content is output verbatim - trim markers on raw/endraw
      # only affect the TEMPLATE content before/after, not the raw content itself

      # Clear any pending trim from the raw tag's -%} - it should NOT affect raw content
      @pending_trim_left = false

      # Use lexer's raw mode to scan until {% endraw %} without tokenizing
      result = @template_lexer.scan_raw_body

      if result
        content, _endraw_trim_left, endraw_trim_right = result

        # Output raw content as-is (no trimming)
        @builder.write_raw(content) unless content.empty?

        # Set pending trim based on endraw's trim_right (-%})
        # This affects the template content AFTER {% endraw %}
        @pending_trim_left = endraw_trim_right

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
      raise SyntaxError, 'Syntax Error: Template name must be a quoted string' unless lexer.current == ExpressionLexer::STRING

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
            # Handle "with expr" or "with name: value" (name becomes both with expr AND keyword arg)
            if lexer.current == ExpressionLexer::IDENTIFIER
              expr_name = lexer.value
              lexer.advance
              if lexer.current == ExpressionLexer::COLON
                # "with name:" - name is the with expression, and name: value is also a keyword arg
                with_expr = expr_name
                lexer.advance  # consume colon
                args[expr_name] = extract_arg_value(lexer)
              else
                # "with expr" where expr might have dots/brackets
                with_expr = expr_name + extract_expression_continuation(lexer)
              end
            else
              # "with 123" or other literal
              with_expr = extract_expression_string(lexer)
            end
          when 'for'
            lexer.advance
            # Handle "for expr" or "for name: value" (name becomes both for expr AND keyword arg)
            if lexer.current == ExpressionLexer::IDENTIFIER
              expr_name = lexer.value
              lexer.advance
              if lexer.current == ExpressionLexer::COLON
                # "for name:" - name is the for expression, and name: value is also a keyword arg
                for_expr = expr_name
                lexer.advance  # consume colon
                args[expr_name] = extract_arg_value(lexer)
              else
                # "for expr" where expr might have dots/brackets
                for_expr = expr_name + extract_expression_continuation(lexer)
              end
            else
              # "for (1..3)" or other literal/expression
              for_expr = extract_expression_string(lexer)
            end
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

      @builder.const_render(partial_name, args)
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

          # Peek ahead to see if this is a keyword argument (identifier followed by colon)
          if paren_depth == 0
            saved_state = lexer.save_state
            saved_value = lexer.value
            lexer.advance
            if lexer.current == ExpressionLexer::COLON
              # This identifier is a keyword arg name - restore state so caller sees it
              lexer.restore_state(saved_state)
              break
            end
            parts << saved_value
          else
            parts << lexer.value
            lexer.advance
          end
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

    # Extract continuation of an expression after first identifier has been consumed
    # Used for "with name.prop" where "name" is already consumed
    def extract_expression_continuation(lexer)
      parts = []

      loop do
        case lexer.current
        when ExpressionLexer::DOT
          parts << '.'
          lexer.advance
          if lexer.current == ExpressionLexer::IDENTIFIER
            parts << lexer.value
            lexer.advance
          end
        when ExpressionLexer::LBRACKET
          parts << '['
          lexer.advance
          while lexer.current != ExpressionLexer::EOF && lexer.current != ExpressionLexer::RBRACKET
            case lexer.current
            when ExpressionLexer::NUMBER, ExpressionLexer::STRING, ExpressionLexer::IDENTIFIER
              parts << lexer.value
            end
            lexer.advance
          end
          parts << ']'
          lexer.advance if lexer.current == ExpressionLexer::RBRACKET
        else
          break
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
      # Use expression lexer for proper tokenization
      lexer = ExpressionLexer.new(tag_args)
      lexer.advance

      # First token is the partial name (string, identifier expression, nil, or number)
      if lexer.current == :STRING
        partial_name = lexer.value
        dynamic_name = false
        lexer.advance
      elsif lexer.current == :IDENTIFIER
        # Parse full expression (e.g., item.template, products[0].name)
        partial_name = parse_include_expression(lexer)
        dynamic_name = true
      elsif lexer.current == :NIL
        # {% include nil %} - invalid template name
        partial_name = nil
        dynamic_name = false
        invalid_name = true
        lexer.advance
      elsif lexer.current == :NUMBER
        # {% include 123 %} - invalid template name
        partial_name = lexer.value
        dynamic_name = false
        invalid_name = true
        lexer.advance
      else
        return # Invalid syntax
      end

      args = {}
      with_expr = nil
      for_expr = nil
      as_alias = nil

      # Parse optional modifiers: with, for, as, and keyword args
      while !lexer.eos?
        case lexer.current
        when :IDENTIFIER
          keyword = lexer.value
          case keyword
          when 'with'
            lexer.advance
            # Handle "with expr" or "with name: value" (name becomes both with expr AND keyword arg)
            if lexer.current == :IDENTIFIER
              expr_name = lexer.value
              lexer.advance
              if lexer.current == :COLON
                # "with name:" - name is the with expression, and name: value is also a keyword arg
                with_expr = expr_name
                lexer.advance  # consume colon
                val = parse_include_arg_value(lexer)
                args[expr_name] = val
              else
                # "with expr" where expr might have dots/brackets
                with_expr = expr_name + parse_include_expression_continuation(lexer)
              end
            else
              # "with 123" or other literal
              with_expr = parse_include_expression(lexer)
            end
          when 'for'
            lexer.advance
            for_expr = parse_include_expression(lexer)
          when 'as'
            lexer.advance
            if lexer.current == :IDENTIFIER
              as_alias = lexer.value
              lexer.advance
            end
          else
            # Check for keyword arg (name: value)
            # Save position and look ahead for colon
            key = lexer.value
            lexer.advance  # consume identifier
            if lexer.current == :COLON
              lexer.advance  # consume colon
              val = parse_include_arg_value(lexer)
              args[key] = val
            end
            # Otherwise, it was just an identifier we skipped
          end
        when :COMMA
          lexer.advance
        else
          lexer.advance  # skip unknown tokens
        end
      end

      args['__with__'] = with_expr if with_expr
      args['__for__'] = for_expr if for_expr
      args['__as__'] = as_alias if as_alias
      args['__dynamic_name__'] = partial_name if dynamic_name
      args['__invalid_name__'] = true if invalid_name

      if !dynamic_name && !invalid_name
        @builder.const_include(partial_name, args)
      else
        @builder.include_partial(partial_name, args)
      end
      false
    end

    # Parse an expression for include with/for (returns string representation)
    def parse_include_expression(lexer)
      parts = []

      # Handle range literals: (1..10)
      if lexer.current == :LPAREN
        parts << '('
        lexer.advance
        while !lexer.eos? && lexer.current != :RPAREN
          case lexer.current
          when :NUMBER
            parts << lexer.value
          when :DOTDOT
            parts << '..'
          when :IDENTIFIER
            parts << lexer.value
          else
            parts << lexer.current.to_s
          end
          lexer.advance
        end
        parts << ')'
        lexer.advance if lexer.current == :RPAREN
        return parts.join
      end

      # Handle simple expressions: var, var.prop, var[0]
      # Stop at keywords: with, for, as, or potential keyword arg (identifier followed by colon)
      while !lexer.eos?
        case lexer.current
        when :IDENTIFIER
          val = lexer.value
          # Stop at reserved keywords
          break if %w[with for as].include?(val)
          # Check for keyword arg (identifier followed by colon)
          if lexer.peek == :COLON
            break
          end
          parts << val
          lexer.advance
        when :DOT
          parts << '.'
          lexer.advance
        when :LBRACKET
          parts << '['
          lexer.advance
          while !lexer.eos? && lexer.current != :RBRACKET
            case lexer.current
            when :NUMBER, :STRING, :IDENTIFIER
              parts << lexer.value
            else
              parts << lexer.current.to_s
            end
            lexer.advance
          end
          parts << ']'
          lexer.advance if lexer.current == :RBRACKET
        else
          break
        end
      end

      parts.join
    end

    # Parse continuation of an expression after first identifier has been consumed
    # Used for "with name.prop" where "name" is already consumed
    def parse_include_expression_continuation(lexer)
      parts = []

      while !lexer.eos?
        case lexer.current
        when :DOT
          parts << '.'
          lexer.advance
          if lexer.current == :IDENTIFIER
            parts << lexer.value
            lexer.advance
          end
        when :LBRACKET
          parts << '['
          lexer.advance
          while !lexer.eos? && lexer.current != :RBRACKET
            case lexer.current
            when :NUMBER, :STRING, :IDENTIFIER
              parts << lexer.value
            else
              parts << lexer.current.to_s
            end
            lexer.advance
          end
          parts << ']'
          lexer.advance if lexer.current == :RBRACKET
        else
          break
        end
      end

      parts.join
    end

    # Parse a value for include keyword arg
    def parse_include_arg_value(lexer)
      case lexer.current
      when :STRING
        val = lexer.value
        lexer.advance
        val
      when :NUMBER
        val_str = lexer.value
        lexer.advance
        val_str.include?('.') ? val_str.to_f : val_str.to_i
      when :IDENTIFIER
        # Variable reference - look up at runtime
        expr = parse_include_expression(lexer)
        { __var__: expr }
      else
        lexer.advance
        nil
      end
    end

    def expect_eos(lexer)
      return if lexer.eos?

      raise SyntaxError, "Unexpected token #{lexer.current} after expression"
    end
  end
end
