# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Focused contracts for the cross-process compiler/artifact architecture.
class ArchitectureBoundariesTest < Minitest::Test
  def test_context_compile_cache_includes_parse_options
    context = LiquidIL::Context.new
    optimized = context.parse("{% assign x = 1 %}{{ x }}", optimize: true)
    unoptimized = context.parse("{% assign x = 1 %}{{ x }}", optimize: false)

    refute_same optimized, unoptimized
    assert_same optimized, context.parse("{% assign x = 1 %}{{ x }}", optimize: true)
    assert_equal optimized.render, unoptimized.render
  end

  def test_one_loaded_artifact_renders_repeatedly_with_different_assigns
    source = "Hello {{ customer.name }}: {{ total }}"
    blob = LiquidIL.parse(source).to_artifact
    artifact = LiquidIL.load_artifact(blob) # load exactly once

    assert_equal "Hello Ada: 10", artifact.render("customer" => { "name" => "Ada" }, "total" => 10)
    assert_equal "Hello Grace: 27", artifact.render("customer" => { "name" => "Grace" }, "total" => 27)
    assert_equal "Hello : ", artifact.render({})
  end

  def test_literal_pool_contains_only_compile_time_template_data
    raw = "<article>#{"x" * (LiquidIL::RubyCompiler::LITERAL_POOL_MIN_BYTES + 32)}</article>"
    template = LiquidIL.parse("#{raw}{{ value }}")

    assert_equal [raw], template.partial_constants
    assert_includes template.compiled_source, "_pc[0]"
    refute_includes template.partial_constants.inspect, "first assign"

    artifact = LiquidIL.load_artifact(template.to_artifact)
    assert_equal "#{raw}first assign", artifact.render("value" => "first assign")
    assert_equal "#{raw}second assign", artifact.render("value" => "second assign")
  end

  def test_nested_inlined_partials_do_not_alias_literal_pool_slots
    filesystem = Class.new do
      def initialize(files) = @files = files
      def read_template_file(name, _context = nil) = @files[name.to_s]
    end.new(
      "outer" => "OUT:{% render 'nav' %}",
      "nav" => "NAV-#{"n" * 1100}",
      "panel" => "PANEL-#{"p" * 1100}",
    )
    template = LiquidIL::Context.new(file_system: filesystem)
      .parse("{% render 'outer' %}|{% render 'panel' %}")
    expected = "OUT:NAV-#{"n" * 1100}|PANEL-#{"p" * 1100}"

    assert_equal expected, template.render
    loaded = LiquidIL.load_artifact(template.to_artifact)
    assert_equal expected, loaded.render
  end

  def test_literal_pool_preserves_string_encoding
    source = ("x" * (LiquidIL::RubyCompiler::LITERAL_POOL_MIN_BYTES + 8))
      .force_encoding(Encoding::ISO_8859_1)
    template = LiquidIL.parse(source)
    loaded = LiquidIL.load_artifact(template.to_artifact)

    assert_equal Encoding::ISO_8859_1, loaded.partial_constants.first.encoding
    assert_equal source.b, loaded.render.b
  end

  def test_short_literals_stay_in_iseq
    template = LiquidIL.parse("short {{ value }}")
    assert_nil template.partial_constants
    refute_includes template.compiled_source, "_pc["
  end

  def test_artifact_rejects_wrong_compiler_runtime_abi
    blob = LiquidIL.parse("hello").to_artifact
    stamp_len = blob.getbyte(5)
    abi_len_pos = 6 + stamp_len
    abi_pos = abi_len_pos + 1
    bad = blob.dup
    bad.setbyte(abi_pos, bad.getbyte(abi_pos) ^ 1)

    assert_raises(LiquidIL::StaleArtifactError) { LiquidIL.load_artifact(bad) }
  end

  def test_artifact_digest_covers_metadata_segments
    raw = "x" * (LiquidIL::RubyCompiler::LITERAL_POOL_MIN_BYTES + 20)
    blob = LiquidIL.parse(raw).to_artifact
    bad = blob.dup
    bad.setbyte(bad.bytesize - 2, bad.getbyte(bad.bytesize - 2) ^ 1)

    assert_raises(LiquidIL::CorruptArtifactError) { LiquidIL.load_artifact(bad) }
  end

  def test_one_compiled_artifact_is_concurrent_with_distinct_assigns
    artifact = LiquidIL.load_artifact(LiquidIL.parse("{{ id }}:{{ value }}").to_artifact)
    threads = 8.times.map do |id|
      Thread.new { 100.times.map { artifact.render("id" => id, "value" => id * 10) } }
    end
    threads.each_with_index do |thread, id|
      assert_equal ["#{id}:#{id * 10}"], thread.value.uniq
    end
  end

  def test_bound_partial_self_argument_keeps_caller_scope
    filesystem = Class.new do
      def read_template_file(_name, _context = nil)
        "{%- assign x = 2 -%}{{- self.x -}}|{{- x -}}"
      end
    end.new
    template = LiquidIL::Context.new(file_system: filesystem)
      .parse("{%- assign x = 1 -%}{%- render 'snippet', self: self -%}")

    assert_equal "1|2", template.render
    loaded = LiquidIL.load_artifact(template.to_artifact)
    assert_equal "1|2", loaded.render
  end

  def test_compiled_artifact_and_template_share_strict_render_semantics
    template = LiquidIL.parse("{{ missing }}")
    artifact = LiquidIL.load_artifact(template.to_artifact)

    assert_raises(LiquidIL::UndefinedVariable) do
      template.render!({}, strict_variables: true)
    end
    assert_raises(LiquidIL::UndefinedVariable) do
      artifact.render!({}, strict_variables: true)
    end
  end
end
