# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "liquid"
require_relative "../lib/liquid_il"

class ArityTwoFileSystem
  attr_reader :calls

  def initialize(templates)
    @templates = templates
    @calls = []
  end

  # Liquid-compatible signature used by many FileSystem implementations
  def read_template_file(name, context)
    raise "context is required" if context.nil?
    @calls << [name, context]
    @templates[name]
  end
end

class FileSystemCompatTest < Minitest::Test
  def test_static_render_supports_read_template_file_with_context_arg
    fs = ArityTwoFileSystem.new("part" => "OK")
    ctx = LiquidIL::Context.new(file_system: fs)

    assert_equal "OK", ctx.render("{% render 'part' %}")
    assert_equal 1, fs.calls.length
    assert_equal "part", fs.calls[0][0]
    assert_instance_of LiquidIL::Context, fs.calls[0][1]
  end

  def test_dynamic_include_supports_read_template_file_with_context_arg
    fs = ArityTwoFileSystem.new("part" => "{{ value }}")
    ctx = LiquidIL::Context.new(file_system: fs)

    out = ctx.render("{% assign p = 'part' %}{% include p %}", "value" => "dynamic")
    assert_equal "dynamic", out
    assert_equal 1, fs.calls.length
    assert_equal "part", fs.calls[0][0]
    assert_instance_of LiquidIL::Scope, fs.calls[0][1]
  end

  def test_liquid_local_file_system_works
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "_header.liquid"), "HEADER {{ name }}")

      fs = Liquid::LocalFileSystem.new(dir)
      ctx = LiquidIL::Context.new(file_system: fs)

      assert_equal "HEADER Bob", ctx.render("{% render 'header' %}", "name" => "Bob")
    end
  end

  def test_liquid_blank_file_system_missing_partial_raises_at_compile_time
    fs = Liquid::BlankFileSystem.new
    ctx = LiquidIL::Context.new(file_system: fs)

    error = assert_raises(RuntimeError) { ctx.render("{% render 'missing' %}") }
    assert_includes error.message, "Cannot load partial"
  end
end
