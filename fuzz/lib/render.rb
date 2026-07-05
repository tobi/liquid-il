# frozen_string_literal: true

module Fuzz
  # Turns generator AST nodes (plain Hashes, see gen.rb) into Liquid source
  # text. Kept separate from Gen so the shrinker can re-render mutated ASTs
  # (dropped children, shrunk literals, empty bodies) without regenerating
  # anything -- every method here must tolerate degenerate/empty structure
  # (empty branches, empty bodies, empty arg lists) since that's exactly
  # what shrinking produces on the way to a minimal repro.
  module Render
    module_function

    def block_to_source(stmts)
      Array(stmts).map { |s| stmt_source(s) }.join
    end

    def stmt_source(stmt)
      case stmt[:type]
      when :raw then stmt[:text].to_s
      when :output then "#{otag(stmt)} #{expr_source(stmt[:expr])} #{ctag(stmt)}"
      when :echo then "#{ttag(stmt)} echo #{expr_source(stmt[:expr])} #{ttag_close(stmt)}"
      when :assign then "#{ttag(stmt)} assign #{stmt[:name]} = #{expr_source(stmt[:expr])} #{ttag_close(stmt)}"
      when :increment then "#{ttag(stmt)} increment #{stmt[:name]} #{ttag_close(stmt)}"
      when :decrement then "#{ttag(stmt)} decrement #{stmt[:name]} #{ttag_close(stmt)}"
      when :break then "#{ttag(stmt)} break #{ttag_close(stmt)}"
      when :continue then "#{ttag(stmt)} continue #{ttag_close(stmt)}"
      when :cycle then cycle_source(stmt)
      when :comment then "{% comment %}#{sanitize(stmt[:text], "endcomment")}{% endcomment %}"
      when :raw_tag then "{% raw %}#{sanitize(stmt[:text], "endraw")}{% endraw %}"
      when :capture then "#{ttag(stmt)} capture #{stmt[:name]} #{ttag_close(stmt)}#{block_to_source(stmt[:body])}{% endcapture %}"
      when :if then if_source(stmt, "if")
      when :unless then if_source(stmt, "unless")
      when :case then case_source(stmt)
      when :for then for_source(stmt)
      when :tablerow then tablerow_source(stmt)
      when :render then render_or_include_source(stmt, "render")
      when :include then render_or_include_source(stmt, "include")
      when :liquid_block then liquid_block_source(stmt)
      else
        "" # shrinker may zero out a node's fields; render as a no-op rather than crash
      end
    end

    # --- whitespace-control tag helpers -------------------------------
    # A single `ws:` flag per node controls all of that node's own
    # delimiters ({%- ... -%}) -- a simplification vs. per-tag control, but
    # it exercises whitespace-trim parsing/rendering on every tag kind.
    def otag(stmt) = stmt[:ws] ? "{{-" : "{{"
    def ctag(stmt) = stmt[:ws] ? "-}}" : "}}"
    def ttag(stmt) = stmt[:ws] ? "{%-" : "{%"
    def ttag_close(stmt) = stmt[:ws] ? "-%}" : "%}"

    def sanitize(text, forbidden)
      text.to_s.gsub(/#{Regexp.escape(forbidden)}/i, "x")
    end

    def cycle_source(stmt)
      values = Array(stmt[:values]).map { |v| expr_source(v) }
      values = ["\"\""] if values.empty?
      body = stmt[:name] ? "#{string_literal(stmt[:name])}: #{values.join(", ")}" : values.join(", ")
      "#{ttag(stmt)} cycle #{body} #{ttag_close(stmt)}"
    end

    def if_source(stmt, keyword)
      branches = Array(stmt[:branches])
      return "" if branches.empty? && !stmt[:else_body]

      out = +""
      branches.each_with_index do |br, i|
        cond = expr_source(br[:cond])
        out << if i.zero?
          "#{ttag(stmt)} #{keyword} #{cond} #{ttag_close(stmt)}"
        else
          "{% elsif #{cond} %}"
        end
        out << block_to_source(br[:body])
      end
      if branches.empty?
        # Degenerate (shrunk to zero branches): keep it parseable by
        # emitting a trivially-false condition so only else_body survives.
        out << "#{ttag(stmt)} #{keyword} false #{ttag_close(stmt)}"
      end
      if stmt[:else_body]
        out << "{% else %}"
        out << block_to_source(stmt[:else_body])
      end
      out << "{% end#{keyword} %}"
      out
    end

    def case_source(stmt)
      out = +"#{ttag(stmt)} case #{expr_source(stmt[:expr])} #{ttag_close(stmt)}"
      Array(stmt[:whens]).each do |w|
        values = Array(w[:values]).map { |v| expr_source(v) }
        values = ["nil"] if values.empty?
        out << "{% when #{values.join(", ")} %}"
        out << block_to_source(w[:body])
      end
      if stmt[:else_body]
        out << "{% else %}"
        out << block_to_source(stmt[:else_body])
      end
      out << "{% endcase %}"
      out
    end

    def for_source(stmt)
      mods = []
      mods << "reversed" if stmt[:reversed]
      mods << "limit: #{expr_source(stmt[:limit])}" if stmt[:limit]
      mods << (stmt[:offset_continue] ? "offset: continue" : "offset: #{expr_source(stmt[:offset])}") if stmt[:offset] || stmt[:offset_continue]
      mod_src = mods.empty? ? "" : " #{mods.join(" ")}"
      out = +"#{ttag(stmt)} for #{stmt[:var]} in #{expr_source(stmt[:coll])}#{mod_src} #{ttag_close(stmt)}"
      out << block_to_source(stmt[:body])
      if stmt[:else_body]
        out << "{% else %}"
        out << block_to_source(stmt[:else_body])
      end
      out << "{% endfor %}"
      out
    end

    def tablerow_source(stmt)
      mods = []
      mods << "cols: #{expr_source(stmt[:cols])}" if stmt[:cols]
      mods << "limit: #{expr_source(stmt[:limit])}" if stmt[:limit]
      mods << "offset: #{expr_source(stmt[:offset])}" if stmt[:offset]
      mod_src = mods.empty? ? "" : " #{mods.join(" ")}"
      "#{ttag(stmt)} tablerow #{stmt[:var]} in #{expr_source(stmt[:coll])}#{mod_src} #{ttag_close(stmt)}" \
        "#{block_to_source(stmt[:body])}{% endtablerow %}"
    end

    def render_or_include_source(stmt, tag_name)
      return "" unless stmt[:name]

      head = +"#{tag_name} #{string_literal(stmt[:name])}"
      case stmt[:mode]
      when :with
        head << " with #{expr_source(stmt[:target_expr])}"
        head << " as #{stmt[:as_name]}" if stmt[:as_name]
      when :for
        head << " for #{expr_source(stmt[:target_expr])}"
        head << " as #{stmt[:as_name]}" if stmt[:as_name]
      end
      args = (stmt[:args] || {}).map { |k, v| "#{k}: #{expr_source(v)}" }
      head << ", #{args.join(", ")}" unless args.empty?
      "{% #{head} %}"
    end

    def liquid_block_source(stmt)
      lines = Array(stmt[:lines]).map do |line|
        case line[:type]
        when :assign then "assign #{line[:name]} = #{expr_source(line[:expr])}"
        when :echo then "echo #{expr_source(line[:expr])}"
        else nil
        end
      end.compact
      return "" if lines.empty?

      "{% liquid\n#{lines.join("\n")}\n%}"
    end

    # --- expressions ---------------------------------------------------

    def expr_source(expr)
      return "nil" unless expr

      case expr[:type]
      when :lit then literal_source(expr[:value])
      when :chain then chain_source(expr)
      when :range then "(#{expr_source(expr[:from])}..#{expr_source(expr[:to])})"
      when :filter then filter_source(expr)
      when :binop then "#{expr_source(expr[:left])} #{expr[:op]} #{expr_source(expr[:right])}"
      when :logical then "#{expr_source(expr[:left])} #{expr[:op]} #{expr_source(expr[:right])}"
      else "nil"
      end
    end

    def chain_source(expr)
      base = expr[:base] == :self ? "self" : expr[:base].to_s
      out = +base
      Array(expr[:accessors]).each do |acc|
        if acc[:dot]
          out << ".#{acc[:dot]}"
        elsif acc[:bracket]
          out << "[#{expr_source(acc[:bracket])}]"
        end
      end
      out
    end

    def filter_source(expr)
      args = Array(expr[:args]).map { |a| expr_source(a) }
      arg_src = args.empty? ? "" : ": #{args.join(", ")}"
      "#{expr_source(expr[:target])} | #{expr[:name]}#{arg_src}"
    end

    def literal_source(value)
      case value
      when nil then "nil"
      when true then "true"
      when false then "false"
      when Integer, Float then value.to_s
      when String then string_literal(value)
      else "nil" # shrinker artifact guard: never emit a non-scalar literal
      end
    end

    def string_literal(s)
      s = s.to_s
      if !s.include?('"')
        %("#{s}")
      elsif !s.include?("'")
        %('#{s}')
      else
        %("#{s.gsub('"', "")}")
      end
    end
  end
end
