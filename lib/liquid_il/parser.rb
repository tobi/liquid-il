# frozen_string_literal: true

module LiquidIL
  # Recursive descent parser that emits IL directly
  class Parser
    attr_reader :builder

    # Filter aliases - resolved at compile time (lowering)
    FILTER_ALIASES = {
      "h" => "escape",
    }.freeze

    def initialize(source)
      @source = source
      @template_lexer = TemplateLexer.new(source)
      @builder = IL::Builder.new
      @current_token = nil
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

    def parse_block_body(end_tags)
      until template_eos?
        case current_template_type
        when TemplateLexer::RAW
          parse_raw
        when TemplateLexer::VAR
          parse_variable_output
        when TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)

          # Check if this is an end tag we're looking for
          if end_tags && end_tags.include?(tag_name)
            return tag_name
          end

          parse_tag
        end
      end
      nil
    end

    def template_eos?
      current_template_type == TemplateLexer::EOF
    end

    def tag_name_from_content(content)
      content.split(/\s+/, 2).first&.downcase
    end

    def parse_raw
      content = current_template_content
      @builder.write_raw(content) unless content.empty?
      advance_template
    end

    def parse_variable_output
      content = current_template_content
      expr_lexer = ExpressionLexer.new(content)
      expr_lexer.advance

      parse_expression(expr_lexer)
      parse_filters(expr_lexer)
      @builder.write_value

      expect_eos(expr_lexer)
      advance_template
    end

    def parse_tag
      content = current_template_content
      parts = content.split(/\s+/, 2)
      tag_name = parts[0]&.downcase
      tag_args = parts[1] || ""

      case tag_name
      when "if"
        advance_template
        parse_if_tag(tag_args)
      when "unless"
        advance_template
        parse_unless_tag(tag_args)
      when "case"
        advance_template
        parse_case_tag(tag_args)
      when "for"
        advance_template
        parse_for_tag(tag_args)
      when "tablerow"
        advance_template
        parse_tablerow_tag(tag_args)
      when "assign"
        advance_template
        parse_assign_tag(tag_args)
      when "capture"
        advance_template
        parse_capture_tag(tag_args)
      when "increment"
        advance_template
        parse_increment_tag(tag_args)
      when "decrement"
        advance_template
        parse_decrement_tag(tag_args)
      when "cycle"
        advance_template
        parse_cycle_tag(tag_args)
      when "break"
        advance_template
        @builder.push_interrupt(:break)
      when "continue"
        advance_template
        @builder.push_interrupt(:continue)
      when "echo"
        advance_template
        parse_echo_tag(tag_args)
      when "liquid"
        advance_template
        parse_liquid_tag(tag_args)
      when "raw"
        advance_template
        parse_raw_tag
      when "comment"
        advance_template
        parse_comment_tag
      when "doc"
        advance_template
        parse_doc_tag
      when "render"
        advance_template
        parse_render_tag(tag_args)
      when "include"
        advance_template
        parse_include_tag(tag_args)
      when "#"
        # Inline comment, skip
        advance_template
      else
        # Unknown tag - skip for now
        advance_template
      end
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
        keyword_value = lexer.value  # Store original value
        keyword_token = lexer.current
        lexer.advance
        if lexer.current == ExpressionLexer::DOT || lexer.current == ExpressionLexer::LBRACKET
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
      if val_str.include?(".")
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
          if lexer.current == ExpressionLexer::IDENTIFIER
            prop_name = lexer.value
            lexer.advance
            # Optimize known commands
            if %w[size first last].include?(prop_name)
              @builder.lookup_command(prop_name)
            else
              @builder.lookup_const_key(prop_name)
            end
          else
            raise SyntaxError, "Expected property name after '.'"
          end
        when ExpressionLexer::LBRACKET
          lexer.advance
          parse_expression(lexer)
          lexer.expect(ExpressionLexer::RBRACKET)
          @builder.lookup_key
        else
          break
        end
      end
    end

    def parse_range_or_grouped(lexer)
      lexer.advance  # consume (

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
      unless lexer.current == ExpressionLexer::IDENTIFIER
        raise SyntaxError, "Expected filter name after '|'"
      end

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
      kwargs = {}

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

      # Parse body until elsif/else/endif
      end_tag = parse_block_body(%w[elsif else endif])

      case end_tag
      when "elsif"
        @builder.jump(label_end)
        @builder.label(label_else)
        parse_elsif_chain(label_end)
      when "else"
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        parse_block_body(%w[endif])
        advance_template  # consume endif
      when "endif"
        @builder.label(label_else)
        advance_template
      end

      @builder.label(label_end)
    end

    def parse_elsif_chain(label_end)
      content = current_template_content
      parts = content.split(/\s+/, 2)
      condition_str = parts[1] || ""

      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_false(label_else)

      advance_template
      end_tag = parse_block_body(%w[elsif else endif])

      case end_tag
      when "elsif"
        @builder.jump(label_end)
        @builder.label(label_else)
        parse_elsif_chain(label_end)
      when "else"
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        parse_block_body(%w[endif])
        advance_template
      when "endif"
        @builder.label(label_else)
        advance_template
      end
    end

    def parse_unless_tag(condition_str)
      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label
      label_end = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_true(label_else)  # Note: opposite of if

      end_tag = parse_block_body(%w[elsif else endunless])

      case end_tag
      when "elsif"
        @builder.jump(label_end)
        @builder.label(label_else)
        parse_elsif_chain_unless(label_end)
      when "else"
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        parse_block_body(%w[endunless])
        advance_template
      when "endunless"
        @builder.label(label_else)
        advance_template
      end

      @builder.label(label_end)
    end

    def parse_elsif_chain_unless(label_end)
      content = current_template_content
      parts = content.split(/\s+/, 2)
      condition_str = parts[1] || ""

      expr_lexer = ExpressionLexer.new(condition_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      label_else = @builder.new_label

      @builder.is_truthy
      @builder.jump_if_false(label_else)

      advance_template
      end_tag = parse_block_body(%w[elsif else endunless])

      case end_tag
      when "elsif"
        @builder.jump(label_end)
        @builder.label(label_else)
        parse_elsif_chain_unless(label_end)
      when "else"
        @builder.jump(label_end)
        @builder.label(label_else)
        advance_template
        parse_block_body(%w[endunless])
        advance_template
      when "endunless"
        @builder.label(label_else)
        advance_template
      end
    end

    def parse_case_tag(case_expr_str)
      expr_lexer = ExpressionLexer.new(case_expr_str)
      expr_lexer.advance
      parse_expression(expr_lexer)

      @builder.store_temp(0)  # Store case value

      label_end = @builder.new_label

      # Parse until first when or else
      end_tag = parse_block_body(%w[when else endcase])

      while end_tag == "when"
        end_tag = parse_when_clause(label_end)
      end

      if end_tag == "else"
        advance_template
        parse_block_body(%w[endcase])
        advance_template
      elsif end_tag == "endcase"
        advance_template
      end

      @builder.label(label_end)
    end

    def parse_when_clause(label_end)
      content = current_template_content
      parts = content.split(/\s+/, 2)
      when_values_str = parts[1] || ""

      # Parse comma-separated values
      label_body = @builder.new_label
      label_next = @builder.new_label

      # Split on commas or "or" and check each value
      when_values_str.split(/\s*(?:,|\bor\b)\s*/).each do |val_str|
        val_str = val_str.strip
        next if val_str.empty?

        expr_lexer = ExpressionLexer.new(val_str)
        expr_lexer.advance

        @builder.load_temp(0)
        parse_expression(expr_lexer)
        @builder.compare(:eq)
        @builder.jump_if_true(label_body)
      end

      @builder.jump(label_next)
      @builder.label(label_body)

      advance_template
      end_tag = parse_block_body(%w[when else endcase])

      @builder.jump(label_end)
      @builder.label(label_next)

      end_tag
    end

    def parse_for_tag(tag_args)
      # Parse: var_name in collection [limit:N] [offset:N] [reversed]
      match = tag_args.match(/(\w+)\s+in\s+(.+)/)
      raise SyntaxError, "Invalid for tag syntax" unless match

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
        rest = rest.gsub(/\breversed\b/, "")
      end

      # Check for limit
      if rest =~ /\blimit\s*:\s*(\S+)/
        limit_expr = Regexp.last_match(1)
        rest = rest.gsub(/\blimit\s*:\s*\S+/, "")
      end

      # Check for offset
      if rest =~ /\boffset\s*:\s*continue\b/
        offset_continue = true
        rest = rest.gsub(/\boffset\s*:\s*continue\b/, "")
      elsif rest =~ /\boffset\s*:\s*(\S+)/
        offset_expr = Regexp.last_match(1)
        rest = rest.gsub(/\boffset\s*:\s*\S+/, "")
      end

      collection_expr = rest.strip

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

      # Initialize for loop (pops collection, creates iterator)
      @builder.for_init(var_name, loop_name)

      @builder.push_scope
      @builder.push_forloop

      @builder.label(label_loop)
      @builder.for_next(label_continue, label_break)
      @builder.assign(var_name)

      # Render body
      end_tag = parse_block_body(%w[else endfor])

      # Check for interrupts
      @builder.jump_if_interrupt(label_break)

      @builder.label(label_continue)
      @builder.jump(label_loop)

      @builder.label(label_break)
      @builder.pop_forloop
      @builder.pop_scope
      @builder.for_end
      @builder.jump(label_end)

      @builder.label(label_else)
      if end_tag == "else"
        advance_template
        parse_block_body(%w[endfor])
      end

      @builder.label(label_end)
      advance_template  # consume endfor
    end

    def parse_tablerow_tag(tag_args)
      # Similar to for but with table wrapping
      # For now, implement as a simpler version
      parse_for_tag(tag_args)
    end

    def parse_assign_tag(tag_args)
      match = tag_args.match(/([\w-]+)\s*=\s*(.+)/)
      raise SyntaxError, "Invalid assign syntax" unless match

      var_name = match[1]
      value_expr = match[2]

      expr_lexer = ExpressionLexer.new(value_expr)
      expr_lexer.advance
      parse_expression(expr_lexer)
      parse_filters(expr_lexer)

      @builder.assign(var_name)
    end

    def parse_capture_tag(tag_args)
      var_name = tag_args.strip
      raise SyntaxError, "Capture requires variable name" if var_name.empty?

      @builder.push_capture

      parse_block_body(%w[endcapture])
      advance_template

      @builder.pop_capture
      @builder.assign(var_name)
    end

    def parse_increment_tag(tag_args)
      var_name = tag_args.strip
      @builder.increment(var_name)
      @builder.write_value
    end

    def parse_decrement_tag(tag_args)
      var_name = tag_args.strip
      @builder.decrement(var_name)
      @builder.write_value
    end

    def parse_cycle_tag(tag_args)
      # Parse: 'group': val1, val2, val3  OR  val1, val2, val3
      if tag_args =~ /^(['"])(.+?)\1\s*:\s*(.+)$/
        group = Regexp.last_match(2)
        values_str = Regexp.last_match(3)
      else
        group = nil
        values_str = tag_args
      end

      # Parse comma-separated values using expression lexer for proper handling
      values = []
      expr_lexer = ExpressionLexer.new(values_str)
      expr_lexer.advance

      loop do
        case expr_lexer.current
        when ExpressionLexer::STRING
          values << expr_lexer.value
          expr_lexer.advance
        when ExpressionLexer::NUMBER
          val = expr_lexer.value
          values << (val.include?('.') ? val.to_f : val.to_i)
          expr_lexer.advance
        when ExpressionLexer::IDENTIFIER
          values << expr_lexer.value
          expr_lexer.advance
        when ExpressionLexer::EOF
          break
        when ExpressionLexer::COMMA
          expr_lexer.advance
        else
          expr_lexer.advance
        end
      end

      identity = group || values.map(&:to_s).join(",")
      @builder.cycle_step(identity, values)
      @builder.write_value
    end

    def parse_echo_tag(tag_args)
      expr_lexer = ExpressionLexer.new(tag_args)
      expr_lexer.advance
      parse_expression(expr_lexer)
      parse_filters(expr_lexer)
      @builder.write_value
    end

    def parse_liquid_tag(content)
      # The liquid tag contains multiple statements, one per line
      lines = content.split("\n")
      lines.each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        # Parse each line as a tag without delimiters
        parts = line.split(/\s+/, 2)
        tag_name = parts[0]
        tag_args = parts[1] || ""

        case tag_name
        when "echo"
          parse_echo_tag(tag_args)
        when "assign"
          parse_assign_tag(tag_args)
        when "if"
          # For liquid tag, we need to handle block tags differently
          # This is simplified - full implementation would track nested blocks
          parse_simple_if_in_liquid(tag_args, lines)
        when "break"
          @builder.push_interrupt(:break)
        when "continue"
          @builder.push_interrupt(:continue)
        when "increment"
          parse_increment_tag(tag_args)
        when "decrement"
          parse_decrement_tag(tag_args)
        when "cycle"
          parse_cycle_tag(tag_args)
        end
      end
    end

    def parse_simple_if_in_liquid(condition, _lines)
      # Simplified - just evaluates condition
      expr_lexer = ExpressionLexer.new(condition)
      expr_lexer.advance
      parse_expression(expr_lexer)
      @builder.is_truthy
      # Would need to handle the block structure...
    end

    def parse_raw_tag
      # Find endraw and emit everything between as raw
      raw_content = +""
      until template_eos?
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          if tag_name == "endraw"
            advance_template
            break
          end
        end
        # Accumulate content (simplified - would need to reconstruct delimiters)
        raw_content << current_template_content.to_s
        advance_template
      end

      @builder.write_raw(raw_content) unless raw_content.empty?
    end

    def parse_comment_tag
      # Skip until endcomment
      until template_eos?
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          if tag_name == "endcomment"
            advance_template
            break
          end
        end
        advance_template
      end
    end

    def parse_doc_tag
      # Skip until enddoc - doc ignores everything inside including malformed tags
      until template_eos?
        if current_template_type == TemplateLexer::TAG
          tag_name = tag_name_from_content(current_template_content)
          if tag_name == "enddoc"
            advance_template
            break
          end
        end
        advance_template
      end
    end

    def parse_render_tag(tag_args)
      # Parse: 'partial_name' [with variable | for collection] [, var1: val1]
      match = tag_args.match(/(['"])(.+?)\1(.*)/)
      return unless match

      partial_name = match[2]
      rest = match[3].strip

      args = {}
      with_var = nil
      for_collection = nil

      if rest =~ /\bwith\s+(\w+)/
        with_var = Regexp.last_match(1)
        rest = rest.gsub(/\bwith\s+\w+/, "")
      end

      if rest =~ /\bfor\s+(\w+)/
        for_collection = Regexp.last_match(1)
        rest = rest.gsub(/\bfor\s+\w+/, "")
      end

      # Parse keyword args - handle literals
      rest.scan(/([\w-]+)\s*:\s*(?:(['"])(.+?)\2|(-?\d+(?:\.\d+)?)|(\w+))/) do
        key = Regexp.last_match(1)
        if Regexp.last_match(3)       # String literal
          args[key] = Regexp.last_match(3)
        elsif Regexp.last_match(4)    # Number
          num = Regexp.last_match(4)
          args[key] = num.include?('.') ? num.to_f : num.to_i
        elsif Regexp.last_match(5)    # Identifier - look up at runtime
          args[key] = {:__var__ => Regexp.last_match(5)}
        end
      end

      args["__with__"] = with_var if with_var
      args["__for__"] = for_collection if for_collection

      @builder.render_partial(partial_name, args)
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
        return  # Invalid syntax
      end

      args = {}
      with_var = nil
      for_collection = nil
      as_alias = nil

      # Parse "with expression" - support complex expressions like products[0]
      if rest =~ /\bwith\s+([\w\[\]\.]+)/
        with_var = Regexp.last_match(1)
        rest = rest.gsub(/\bwith\s+[\w\[\]\.]+/, "")
      end

      # Parse "for expression"
      if rest =~ /\bfor\s+([\w\[\]\.]+)/
        for_collection = Regexp.last_match(1)
        rest = rest.gsub(/\bfor\s+[\w\[\]\.]+/, "")
      end

      # Parse "as alias" - must come after with/for
      if rest =~ /\bas\s+(\w+)/
        as_alias = Regexp.last_match(1)
        rest = rest.gsub(/\bas\s+\w+/, "")
      end

      # Parse keyword args - handle literals and complex expressions
      rest.scan(/([\w-]+)\s*:\s*(?:(['"])(.+?)\2|(-?\d+(?:\.\d+)?)|([\w\.\[\]]+))/) do
        key = Regexp.last_match(1)
        if Regexp.last_match(3)       # String literal
          args[key] = Regexp.last_match(3)
        elsif Regexp.last_match(4)    # Number
          num = Regexp.last_match(4)
          args[key] = num.include?('.') ? num.to_f : num.to_i
        elsif Regexp.last_match(5)    # Expression - look up at runtime
          args[key] = {:__var__ => Regexp.last_match(5)}
        end
      end

      args["__with__"] = with_var if with_var
      args["__for__"] = for_collection if for_collection
      args["__as__"] = as_alias if as_alias
      args["__dynamic_name__"] = partial_name if dynamic_name

      @builder.include_partial(partial_name, args)
    end

    def expect_eos(lexer)
      unless lexer.eos?
        raise SyntaxError, "Unexpected token #{lexer.current} after expression"
      end
    end
  end
end
