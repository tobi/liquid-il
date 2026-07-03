# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Tests for compile-time code injection vulnerabilities in emitted Ruby.
# These tests verify that template-controlled values (partial names, tag types)
# cannot inject arbitrary Ruby code into the generated source.

class CodeInjectionTest < Minitest::Test
  def setup
    # Clear canary before each test
    $injection_canary = nil
  end

  def teardown
    $injection_canary = nil
  end

  # ════════════════════════════════════════════════════════════
  # RCE via partial name in rescue blocks (lines 414, 417)
  # ════════════════════════════════════════════════════════════

  # These vulnerabilities occur when a partial with a malicious name
  # raises an error at render time. The error message interpolation
  # in the rescue block executes the injected code.

  def test_rce_via_partial_name_in_filter_error_rescue
    # The partial name contains #{...} that would execute if interpolated raw
    malicious_name = 'evil#{$injection_canary = "PWNED_FILTER"}name'

    # Create a file system that returns a partial with malicious name
    # The partial body will raise a FilterRuntimeError
    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          # This will cause a filter error (calling non-existent filter)
          "{{ 'test' | nonexistent_filter_xyz }}"
        else
          raise "Unknown partial: #{name}"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    # Render should not execute the injected code
    begin
      result = ctx.render("{% include '#{malicious_name}' %}")
      # If we get here, check that canary was not set
      assert_nil $injection_canary, "RCE succeeded: injected code executed via FilterRuntimeError rescue"
    rescue => e
      # Error is fine, but canary must not be set
      assert_nil $injection_canary, "RCE succeeded: injected code executed via FilterRuntimeError rescue (despite error)"
    end
  end

  def test_rce_via_partial_name_in_standard_error_rescue
    # The partial name contains #{...} that would execute if interpolated raw
    malicious_name = 'evil#{$injection_canary = "PWNED_STANDARD"}name'

    # Create a file system that returns a partial with malicious name
    # The partial body will cause a StandardError (not LiquidIL-specific)
    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          # Access a variable that will cause an error when converted
          # We'll use a drop that raises in to_s
          "{{ bad_var }}"
        else
          raise "Unknown partial: #{name}"
        end
      end
    end.new

    # Create a drop that raises when converted to string
    bad_drop = Class.new(LiquidIL::Drop) do
      def to_s
        raise "Intentional error for testing"
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    # Render should not execute the injected code
    begin
      result = ctx.render("{% include '#{malicious_name}' %}", "bad_var" => bad_drop)
      # If we get here, check that canary was not set
      assert_nil $injection_canary, "RCE succeeded: injected code executed via StandardError rescue"
    rescue => e
      # Error is fine, but canary must not be set
      assert_nil $injection_canary, "RCE succeeded: injected code executed via StandardError rescue (despite error)"
    end
  end

  def test_rce_via_partial_name_with_backslash_escape
    # Test backslash escaping that could break out of string context
    malicious_name = 'test\"; $injection_canary = \"PWNED_ESCAPE'

    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          "{{ 'test' | nonexistent_filter_xyz }}"
        else
          raise "Unknown partial: #{name}"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    begin
      ctx.render("{% include '#{malicious_name}' %}")
      assert_nil $injection_canary, "RCE succeeded: backslash escape attack"
    rescue => e
      assert_nil $injection_canary, "RCE succeeded: backslash escape attack (despite error)"
    end
  end

  # ════════════════════════════════════════════════════════════
  # RCE via partial name in "Could not find partial" error (line 940)
  # ════════════════════════════════════════════════════════════

  # This vulnerability occurs when trying to include/render a partial
  # that doesn't exist (no file system or partial not found).

  def test_rce_via_missing_partial_name_no_filesystem
    # The partial name contains #{...} that would execute if interpolated raw
    malicious_name = 'missing#{$injection_canary = "PWNED_MISSING"}name'

    # Parse template with malicious partial name, but don't set file system
    # This should trigger the "no file system" error path
    template = LiquidIL::Template.parse("{% include '#{malicious_name}' %}")
    # Explicitly no file system set

    # Render should not execute the injected code
    result = template.render
    assert_nil $injection_canary, "RCE succeeded: injected code executed via missing partial error (no filesystem)"

    # The error message should contain the literal name, not execute it
    assert_includes result, "Could not find partial"
  end

  def test_rce_via_missing_partial_name_with_filesystem
    # The partial name contains #{...} that would execute if interpolated raw
    malicious_name = 'missing#{$injection_canary = "PWNED_MISSING_FS"}name'

    # Create a file system that doesn't have the partial
    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        raise LiquidIL::FileSystemError, "No such partial: #{name}"
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    # Render should not execute the injected code
    begin
      result = ctx.render("{% include '#{malicious_name}' %}")
      assert_nil $injection_canary, "RCE succeeded: injected code executed via missing partial error (with filesystem)"
    rescue => e
      # Error is fine, but canary must not be set
      assert_nil $injection_canary, "RCE succeeded: injected code executed via missing partial error (despite error)"
    end
  end

  # ════════════════════════════════════════════════════════════
  # RCE via tag_type in "Illegal template name" error (line 933)
  # ════════════════════════════════════════════════════════════

  # This vulnerability occurs when a partial name is invalid.
  # The tag_type (include/render) is interpolated into the error message.

  def test_rce_via_invalid_partial_name_include
    # Try to trigger __invalid_name__ path
    # Invalid names might include names with certain characters
    # We need to figure out what makes a name invalid

    # For now, test with a name that might be considered invalid
    # (This test may need adjustment based on actual validation logic)
    malicious_name = 'test#{$injection_canary = "PWNED_INVALID_INC"}name'

    template = LiquidIL::Template.parse("{% include '#{malicious_name}' %}")

    # If this doesn't trigger invalid name, that's also fine
    # The key is the canary must not be set
    begin
      result = template.render
      assert_nil $injection_canary, "RCE succeeded: injected code executed via invalid name error (include)"
    rescue => e
      assert_nil $injection_canary, "RCE succeeded: injected code executed via invalid name error (despite error)"
    end
  end

  def test_rce_via_invalid_partial_name_render
    malicious_name = 'test#{$injection_canary = "PWNED_INVALID_REN"}name'

    template = LiquidIL::Template.parse("{% render '#{malicious_name}' %}")

    begin
      result = template.render
      assert_nil $injection_canary, "RCE succeeded: injected code executed via invalid name error (render)"
    rescue => e
      assert_nil $injection_canary, "RCE succeeded: injected code executed via invalid name error (despite error)"
    end
  end

  # ════════════════════════════════════════════════════════════
  # Verify generated source doesn't contain unescaped interpolations
  # ════════════════════════════════════════════════════════════

  def test_generated_source_escapes_partial_names
    malicious_name = 'test#{pwn}name'

    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          "safe content"
        else
          raise "Unknown partial: #{name}"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% include '#{malicious_name}' %}")

    # The generated source should escape #{ as \#{ in string literals
    # Check that we don't have unescaped #{pwn} in actual code (not comments)
    # The pattern we're looking for is #{pwn} NOT preceded by backslash
    source = template.compiled_source
    
    # Remove comments for analysis
    source_without_comments = source.lines.reject { |l| l.strip.start_with?('#') }.join
    
    # Check for unescaped interpolation in non-comment lines
    # Safe patterns: \#{pwn} (escaped) or in comments
    refute_match(/(?<!\\)#\{pwn\}/, source_without_comments, 
                 "Generated source contains unescaped interpolation from partial name in executable code")
  end

  def test_generated_source_escapes_missing_partial_names
    malicious_name = 'missing#{pwn}name'

    template = LiquidIL::Template.parse("{% include '#{malicious_name}' %}")
    # No file system

    # The generated source should escape #{ as \#{ in string literals
    source = template.compiled_source
    
    # Remove comments for analysis
    source_without_comments = source.lines.reject { |l| l.strip.start_with?('#') }.join
    
    # Check for unescaped interpolation in non-comment lines
    refute_match(/(?<!\\)#\{pwn\}/, source_without_comments,
                 "Generated source contains unescaped interpolation from missing partial name in executable code")
  end

  # ════════════════════════════════════════════════════════════
  # Edge cases with quotes and special characters
  # ════════════════════════════════════════════════════════════

  def test_partial_name_with_single_quotes
    malicious_name = "test'name"

    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          "safe"
        else
          raise "Unknown"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    # This might fail to parse, which is fine
    begin
      ctx.render("{% include '#{malicious_name}' %}")
    rescue LiquidIL::SyntaxError
      # Parse error is acceptable
    end

    assert_nil $injection_canary, "RCE succeeded: single quote in partial name"
  end

  def test_partial_name_with_double_quotes
    malicious_name = 'test"name'

    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          "{{ 'test' | nonexistent_filter_xyz }}"
        else
          raise "Unknown"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    begin
      ctx.render("{% include '#{malicious_name}' %}")
    rescue LiquidIL::SyntaxError
      # Parse error is acceptable
    end

    assert_nil $injection_canary, "RCE succeeded: double quote in partial name"
  end

  def test_partial_name_with_newlines
    malicious_name = "test\nname"

    fs = Class.new do
      define_method(:read_template_file) do |name, _context|
        if name == malicious_name
          "{{ 'test' | nonexistent_filter_xyz }}"
        else
          raise "Unknown"
        end
      end
    end.new

    ctx = LiquidIL::Context.new(file_system: fs)

    begin
      ctx.render("{% include '#{malicious_name}' %}")
    rescue LiquidIL::SyntaxError
      # Parse error is acceptable
    end

    assert_nil $injection_canary, "RCE succeeded: newline in partial name"
  end
end
