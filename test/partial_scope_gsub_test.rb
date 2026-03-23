# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

class TestFileSystem
  def initialize(templates)
    @templates = templates
  end

  def read_template_file(name)
    @templates[name] || @templates["#{name}.liquid"] || raise("Template not found: #{name}")
  end
end

# Test for the _S gsub bug where literal strings containing "_S" are incorrectly modified
class PartialScopeGsubTest < Minitest::Test
  def setup
    @ctx = LiquidIL::Context.new
  end
  
  # Test that literal text containing "_S" is not corrupted when rendered inside a partial
  def test_partial_with_underscore_s_in_output
    # Create a file system with a partial that outputs text containing "_S"
    fs = TestFileSystem.new({ 
      "underscore_s_test" => "ModuleSwatchImageLoader and __SWYM__VERSION__"
    })
    
    og_env = Liquid::Environment.build { |e| e.file_system = fs }
    il_ctx = LiquidIL::Context.new(file_system: fs)
    
    template = "{% render 'underscore_s_test' %}"
    
    # OG Liquid
    og_result = Liquid::Template.parse(template, environment: og_env).render({})
    
    # LiquidIL 
    il_result = il_ctx.render(template, {})
    
    assert_equal og_result, il_result,
      "Partial output containing '_S' should not be corrupted\n" \
      "  OG Liquid: #{og_result.inspect}\n" \
      "  LiquidIL: #{il_result.inspect}"
  end
  
  def test_partial_with_module_search
    fs = TestFileSystem.new({ 
      "search" => "ModuleSearch()"
    })
    
    og_env = Liquid::Environment.build { |e| e.file_system = fs }
    il_ctx = LiquidIL::Context.new(file_system: fs)
    
    template = "{% render 'search' %}"
    
    og_result = Liquid::Template.parse(template, environment: og_env).render({})
    il_result = il_ctx.render(template, {})
    
    assert_equal og_result, il_result,
      "Partial output containing '_S' in 'ModuleSearch' should not be corrupted"
  end
end
