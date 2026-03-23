# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

# Tests that Unicode smart/curly quotes are handled as string delimiters
# in the lexer, matching what users intend when pasting from word processors.
#
# Smart quotes:
#   U+201C " LEFT DOUBLE QUOTATION MARK
#   U+201D " RIGHT DOUBLE QUOTATION MARK
#   U+2018 ' LEFT SINGLE QUOTATION MARK
#   U+2019 ' RIGHT SINGLE QUOTATION MARK
class SmartQuotesTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end

  def test_smart_double_quotes_in_filter_argument
    # U+201C and U+201D around a comma — exactly the pattern from the entity recording
    template = "{{ tags | join: \u201C,\u201D }}"
    result = @ctx.render(template, { "tags" => ["a", "b", "c"] })
    assert_equal "a,b,c", result
  end

  def test_smart_single_quotes_in_filter_argument
    template = "{{ tags | join: \u2018,\u2019 }}"
    result = @ctx.render(template, { "tags" => ["a", "b", "c"] })
    assert_equal "a,b,c", result
  end

  def test_smart_double_quotes_in_string_literal
    template = "{{ \u201Chello\u201D }}"
    result = @ctx.render(template, {})
    assert_equal "hello", result
  end

  def test_smart_single_quotes_in_string_literal
    template = "{{ \u2018hello\u2019 }}"
    result = @ctx.render(template, {})
    assert_equal "hello", result
  end

  def test_smart_quotes_in_if_condition
    template = "{% if x == \u201Cfoo\u201D %}yes{% endif %}"
    result = @ctx.render(template, { "x" => "foo" })
    assert_equal "yes", result
  end

  def test_smart_quotes_empty_string
    template = "{{ \u201C\u201D }}"
    result = @ctx.render(template, {})
    assert_equal "", result
  end

  def test_smart_double_quotes_with_spaces
    template = "{{ tags | join: \u201C, \u201D }}"
    result = @ctx.render(template, { "tags" => ["a", "b"] })
    assert_equal "a, b", result
  end
end
