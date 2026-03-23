# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

# Tests for {% liquid %} tag parity with normal tag parsing.
#
# Every test renders the template with BOTH OG Liquid and LiquidIL,
# asserting they produce identical output. This guarantees our
# expected values aren't made up.
class LiquidTagParityTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  # Render with OG Liquid and LiquidIL, assert both match.
  # If og_env is provided, it's used as OG Liquid's environment (for file_system etc.)
  def assert_renders(template, assigns = {}, msg = nil, og_env: nil, il_ctx: nil)
    il_ctx ||= @ctx

    # OG Liquid
    parse_opts = og_env ? { environment: og_env } : {}
    og_result = Liquid::Template.parse(template, **parse_opts).render(assigns)

    # LiquidIL
    il_result = il_ctx.render(template, assigns)

    assert_equal og_result, il_result,
      "#{msg || 'Output mismatch'}\n  Template: #{template.inspect}\n  Assigns: #{assigns.inspect}\n  OG Liquid: #{og_result.inspect}\n  LiquidIL: #{il_result.inspect}"
  end

  # ── case/when ──────────────────────────────────────────────────

  def test_case_when_match_second
    assert_renders('{% liquid
case x
when "a"
  echo "A"
when "b"
  echo "B"
endcase
%}', { "x" => "b" }, "case/when should only match the correct branch")
  end

  def test_case_when_match_first
    assert_renders('{% liquid
case x
when "a"
  echo "A"
when "b"
  echo "B"
endcase
%}', { "x" => "a" }, "case/when should match first branch")
  end

  def test_case_when_no_match
    assert_renders('{% liquid
case x
when "a"
  echo "A"
when "b"
  echo "B"
endcase
%}', { "x" => "z" }, "case/when with no match should produce empty output")
  end

  def test_case_when_with_else
    assert_renders('{% liquid
case x
when "a"
  echo "A"
else
  echo "default"
endcase
%}', { "x" => "z" }, "case/when/else should fall through to else")
  end

  def test_case_when_else_not_taken
    assert_renders('{% liquid
case x
when "a"
  echo "A"
else
  echo "default"
endcase
%}', { "x" => "a" }, "case/when/else should NOT execute else when a when matches")
  end

  def test_case_when_comma_separated
    assert_renders('{% liquid
case x
when "a", "b"
  echo "AB"
when "c"
  echo "C"
endcase
%}', { "x" => "b" }, "case/when with comma-separated values")
  end

  def test_case_when_integer
    assert_renders('{% liquid
case x
when 1
  echo "one"
when 2
  echo "two"
endcase
%}', { "x" => 2 }, "case/when with integer values")
  end

  def test_case_nested_in_if
    assert_renders('{% liquid
if show
  case x
  when "a"
    echo "A"
  when "b"
    echo "B"
  endcase
endif
%}', { "show" => true, "x" => "b" }, "case/when nested inside if")
  end

  # ── tablerow ───────────────────────────────────────────────────

  def test_tablerow_basic
    assert_renders('{% liquid
tablerow item in items
  echo item
endtablerow
%}', { "items" => [1, 2, 3] }, "tablerow should produce HTML table rows")
  end

  def test_tablerow_with_cols
    assert_renders('{% liquid
tablerow item in items cols:2
  echo item
endtablerow
%}', { "items" => [1, 2, 3, 4] }, "tablerow with cols parameter")
  end

  def test_tablerow_with_limit
    assert_renders('{% liquid
tablerow item in items limit:2
  echo item
endtablerow
%}', { "items" => [1, 2, 3, 4] }, "tablerow with limit parameter")
  end

  def test_tablerow_with_offset
    assert_renders('{% liquid
tablerow item in items offset:1
  echo item
endtablerow
%}', { "items" => [1, 2, 3, 4] }, "tablerow with offset parameter")
  end

  def test_tablerow_empty
    assert_renders('{% liquid
tablerow item in items
  echo item
endtablerow
%}', { "items" => [] }, "tablerow with empty collection")
  end

  # ── ifchanged ──────────────────────────────────────────────────

  def test_ifchanged_basic
    assert_renders('{% liquid
for i in items
  ifchanged
    echo i
  endifchanged
endfor
%}', { "items" => [1, 1, 2, 2, 3] }, "ifchanged should suppress duplicate consecutive outputs")
  end

  def test_ifchanged_all_same
    assert_renders('{% liquid
for i in items
  ifchanged
    echo i
  endifchanged
endfor
%}', { "items" => [1, 1, 1] }, "ifchanged with all same values")
  end

  def test_ifchanged_all_different
    assert_renders('{% liquid
for i in items
  ifchanged
    echo i
  endifchanged
endfor
%}', { "items" => [1, 2, 3] }, "ifchanged with all different values")
  end

  # ── elsif chains (3+ branches) ─────────────────────────────────

  def test_elsif_three_branches
    tmpl = '{% liquid
if x == 1
  echo "one"
elsif x == 2
  echo "two"
elsif x == 3
  echo "three"
else
  echo "other"
endif
%}'
    [1, 2, 3, 4].each do |v|
      assert_renders(tmpl, { "x" => v }, "elsif chain with 3 branches, x=#{v}")
    end
  end

  def test_elsif_four_branches
    tmpl = '{% liquid
if x == 1
  echo "one"
elsif x == 2
  echo "two"
elsif x == 3
  echo "three"
elsif x == 4
  echo "four"
else
  echo "other"
endif
%}'
    [1, 2, 3, 4, 5].each do |v|
      assert_renders(tmpl, { "x" => v }, "elsif chain with 4 branches, x=#{v}")
    end
  end

  # ── unless with else ───────────────────────────────────────────

  def test_unless_else_falsy
    assert_renders('{% liquid
unless x
  echo "yes"
else
  echo "no"
endunless
%}', { "x" => false }, "unless/else should show 'yes' when x is falsy")
  end

  def test_unless_else_truthy
    assert_renders('{% liquid
unless x
  echo "yes"
else
  echo "no"
endunless
%}', { "x" => true }, "unless/else should show 'no' when x is truthy")
  end

  # ── registered/custom tags ─────────────────────────────────────
  # These tags only exist in liquid-il's registry, so we can't compare
  # against OG Liquid. We test expected behavior directly.

  def test_registered_passthrough_tag_in_liquid
    result = @ctx.render('{% liquid
echo "before "
style
  echo "inside"
endstyle
echo " after"
%}')
    assert_equal "before inside after", result,
      "Registered passthrough tag (style) should parse body inside liquid tag"
  end

  def test_custom_registered_tag_in_liquid
    LiquidIL::Tags.register("testblock", end_tag: "endtestblock", mode: :passthrough)

    result = @ctx.render('{% liquid
echo "A"
testblock
  echo "B"
endtestblock
echo "C"
%}')
    assert_equal "ABC", result,
      "Custom registered tag body should be evaluated inside liquid tag"
  end

  # ── inline comments (#) ───────────────────────────────────────

  def test_inline_comment_hash
    assert_renders('{% liquid
echo "A"
# this is a comment
echo "B"
%}', {}, "# comments should be skipped in liquid tag")
  end

  # ── comment block ──────────────────────────────────────────────

  def test_comment_block_in_liquid
    assert_renders('{% liquid
echo "A"
comment
  echo "should not render"
  this is a comment
endcomment
echo "B"
%}', {}, "comment block should skip all content inside liquid tag")
  end

  def test_nested_comment_in_liquid
    assert_renders('{% liquid
echo "A"
comment
  comment
    nested comment
  endcomment
  still in outer comment
endcomment
echo "B"
%}', {}, "Nested comment blocks should be properly handled in liquid tag")
  end

  # ── complex nesting ────────────────────────────────────────────

  def test_for_with_case_inside
    assert_renders('{% liquid
for item in items
  case item
  when 1
    echo "one"
  when 2
    echo "two"
  else
    echo "?"
  endcase
  echo " "
endfor
%}', { "items" => [1, 2, 3] }, "for loop with case/when inside")
  end

  def test_case_with_for_inside
    assert_renders('{% liquid
case mode
when "list"
  for i in items
    echo i
    echo " "
  endfor
when "count"
  echo items.size
endcase
%}', { "mode" => "list", "items" => [1, 2, 3] }, "case/when with for loop inside when branch")
  end

  def test_if_with_tablerow_inside
    assert_renders('{% liquid
if show
  tablerow item in items
    echo item
  endtablerow
endif
%}', { "show" => true, "items" => [1, 2] }, "if with tablerow inside")
  end

  def test_for_with_ifchanged_and_case
    assert_renders('{% liquid
for i in items
  ifchanged
    case i
    when 1
      echo "one"
    when 2
      echo "two"
    else
      echo "other"
    endcase
  endifchanged
endfor
%}', { "items" => [1, 1, 2, 2, 3] }, "for loop with ifchanged containing case/when")
  end

  # ── break and continue inside case ─────────────────────────────

  def test_break_inside_case_in_for
    assert_renders('{% liquid
for i in items
  case i
  when 3
    break
  else
    echo i
  endcase
endfor
%}', { "items" => [1, 2, 3, 4, 5] }, "break inside case/when inside for loop")
  end

  # ── capture inside case ────────────────────────────────────────

  def test_capture_inside_case
    assert_renders('{% liquid
case x
when "a"
  capture result
    echo "hello"
  endcapture
endcase
echo result
%}', { "x" => "a" }, "capture inside case/when")
  end

  # ── increment/decrement ────────────────────────────────────────

  def test_increment_in_liquid
    assert_renders('{% liquid
increment x
increment x
increment x
%}', {}, "increment inside liquid tag")
  end

  def test_decrement_in_liquid
    assert_renders('{% liquid
decrement x
decrement x
%}', {}, "decrement inside liquid tag")
  end

  # ── cycle ──────────────────────────────────────────────────────

  def test_cycle_in_liquid
    assert_renders('{% liquid
for i in items
  cycle "a", "b", "c"
endfor
%}', { "items" => [1, 2, 3, 4, 5] }, "cycle inside liquid tag")
  end

  # ── for/else ───────────────────────────────────────────────────

  def test_for_else_empty
    assert_renders('{% liquid
for item in items
  echo item
else
  echo "empty"
endfor
%}', { "items" => [] }, "for/else with empty collection")
  end

  def test_for_else_nonempty
    assert_renders('{% liquid
for item in items
  echo item
else
  echo "empty"
endfor
%}', { "items" => [1, 2] }, "for/else with non-empty collection")
  end

  # ── render tag ─────────────────────────────────────────────────

  def test_render_in_liquid
    fs = SimpleFileSystem.new({ "snippet" => "Hello {{ name }}" })
    og_env = Liquid::Environment.build { |e| e.file_system = fs }
    il_ctx = LiquidIL::Context.new(file_system: fs)

    assert_renders(
      "{% liquid\nrender 'snippet', name: 'World'\n%}",
      {},
      "render tag should work inside liquid tag",
      og_env: og_env,
      il_ctx: il_ctx,
    )
  end

  # ── assign and echo (regression guard) ─────────────────────────

  def test_assign_and_echo_in_liquid
    assert_renders('{% liquid
assign greeting = "hello"
echo greeting
%}', {}, "assign and echo in liquid tag")
  end

  # ── if/else (regression guard) ─────────────────────────────────

  def test_if_else_in_liquid
    assert_renders('{% liquid
if x
  echo "yes"
else
  echo "no"
endif
%}', { "x" => true }, "if/else in liquid tag")
  end

  def test_if_else_in_liquid_false
    assert_renders('{% liquid
if x
  echo "yes"
else
  echo "no"
endif
%}', { "x" => false }, "if/else in liquid tag (false branch)")
  end

  # ── AND short-circuit followed by if/else (bug repro) ──────────

  def test_and_condition_followed_by_assign_inside_if_else
    # Reproduces a bug where `if cond1 and cond2` inside an outer `if`
    # was miscompiled when the instruction after the inner `endif` was an
    # assignment (CONST_FALSE + ASSIGN). The CONST_FALSE was falsely
    # identified as an AND short-circuit pattern, breaking the outer if/else.
    assert_renders(
      '{% if product != blank %}' \
      '{% liquid ' \
      '  assign x = false ' \
      '  if a and b ' \
      '    assign x = true ' \
      '  endif ' \
      '  assign y = false ' \
      '  if c and d ' \
      '    assign y = true ' \
      '  endif ' \
      '%}' \
      'IF_BRANCH x={{ x }} y={{ y }}' \
      '{% else %}' \
      'ELSE_BRANCH' \
      '{% endif %}',
      { "product" => "something", "a" => true, "b" => true, "c" => false, "d" => true },
      "AND inside if/else: should render IF_BRANCH with correct assign values"
    )
  end

  def test_and_condition_false_outer_renders_else
    # When outer condition is false, else branch should be rendered
    assert_renders(
      '{% if show %}' \
      '{% liquid ' \
      '  assign x = false ' \
      '  if a and b ' \
      '    assign x = true ' \
      '  endif ' \
      '  assign y = false ' \
      '%}' \
      'IF_BRANCH x={{ x }}' \
      '{% else %}' \
      'ELSE_BRANCH' \
      '{% endif %}',
      { "show" => false, "a" => true, "b" => false },
      "AND inside if/else: false outer condition should render ELSE_BRANCH"
    )
  end

  def test_case_inside_for_does_not_eat_subsequent_content
    # case/when inside a for loop causes content after endfor to be
    # compiled inside the last when-clause body. When the for loop
    # iterates zero times, that content is never emitted.
    # This is the root cause of the Dawn footer disappearing.
    assert_renders(
      '{%- for i in items -%}{%- case i -%}{%- when "a" -%}A{%- endcase -%}{%- endfor -%}AFTER',
      { "items" => [] },
      "Content after endfor must render when for loop body is empty"
    )
  end
end

# Tests for custom tags (with handlers) inside {% liquid %}.
# These can't compare against OG Liquid since the handlers are liquid-il specific.
class LiquidTagCustomTagTest < Minitest::Test
  module WrapHandler
    class << self
      def before_block(scope, output, arguments)
        output << "[BEFORE]"
        {}
      end

      def after_block(scope, output, state)
        output << "[AFTER]"
      end
    end
  end

  module FormHandler
    class << self
      def before_block(scope, output, arguments)
        type = arguments[0]
        scope.push_scope
        scope["form"] = { "type" => type }
        output << "<form>"
        {}
      end

      def after_block(scope, output, state)
        output << "</form>"
        scope.pop_scope
      end
    end
  end

  def test_custom_block_tag_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrap", end_tag: "endwrap", mode: :custom, handler: WrapHandler)

    normal = ctx.render("{% wrap %}body{% endwrap %}")
    liquid = ctx.render("{% liquid\nwrap\n  echo \"body\"\nendwrap\n%}")

    assert_equal normal, liquid
    assert_equal "[BEFORE]body[AFTER]", liquid
  end

  def test_custom_block_tag_with_scope_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("form", end_tag: "endform", mode: :custom, handler: FormHandler)

    normal = ctx.render("{% form 'contact' %}{{ form.type }}{% endform %}")
    liquid = ctx.render("{% liquid\nform 'contact'\n  echo form.type\nendform\n%}")

    assert_equal normal, liquid
    assert_equal "<form>contact</form>", liquid
  end

  def test_custom_block_tag_nested_in_if_in_liquid
    ctx = LiquidIL::Context.new
    ctx.register_tag("wrap", end_tag: "endwrap", mode: :custom, handler: WrapHandler)

    result = ctx.render('{% liquid
if show
  wrap
    echo "inside"
  endwrap
endif
%}', { "show" => true })

    assert_equal "[BEFORE]inside[AFTER]", result
  end

  def test_discard_tag_in_liquid
    captured = nil
    LiquidIL::Tags.register("schema", end_tag: "endschema", mode: :discard,
      on_parse: ->(raw_body, _ctx) { captured = raw_body })

    ctx = LiquidIL::Context.new
    result = ctx.render('{% liquid
echo "before"
schema
  {"key": "value"}
endschema
echo "after"
%}')

    assert_equal "beforeafter", result
    refute_nil captured, "on_parse callback should have fired for discard tag inside liquid"
  end
end

# Minimal file system shared by OG Liquid and LiquidIL
class SimpleFileSystem
  def initialize(templates)
    @templates = templates
  end

  def read_template_file(name)
    @templates[name] || @templates["#{name}.liquid"] || raise("Template not found: #{name}")
  end
end
