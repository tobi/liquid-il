# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/liquid_il"

# The framed artifact envelope: the persisted compiled-template string
# (memcache/DB) loaded by a process that never saw the template source.
class ArtifactTest < Minitest::Test
  class StubFS
    def initialize(templates) = @templates = templates
    def read_template_file(name, _ctx = nil) = @templates[name.to_s]
  end

  def compile(source, partials: nil)
    if partials
      LiquidIL::Context.new(file_system: StubFS.new(partials)).parse(source)
    else
      LiquidIL::Template.parse(source)
    end
  end

  def test_roundtrip_simple
    template = compile("Hello {{ name }}!")
    blob = template.to_artifact
    restored = LiquidIL::Artifact.load(blob)
    assert_equal "Hello World!", restored.render("name" => "World")
    assert_equal template.render("name" => "World"), restored.render("name" => "World")
  end

  def test_roundtrip_with_partials
    template = compile(
      "{% render 'item' with v as item %}|{% include 'inc' %}",
      partials: { "item" => "[{{ item }}]", "inc" => "I={{ x }}" }
    )
    blob = template.to_artifact
    restored = LiquidIL::Artifact.load(blob)
    assigns = { "v" => "a", "x" => "b" }
    assert_equal template.render(assigns), restored.render(assigns)
  end

  def test_artifact_magic
    blob = compile("hi").to_artifact
    assert LiquidIL::Artifact.artifact?(blob)
    assert_equal "LQIL", blob.byteslice(0, 4)
    refute LiquidIL::Artifact.artifact?(Marshal.dump({}))
    refute LiquidIL::Artifact.artifact?(nil)
  end

  def test_artifact_does_not_embed_source
    source = "XyZZy_source_marker {{ v }}"
    blob = compile(source).to_artifact
    refute_includes blob, "XyZZy_source_marker {{ v }}"[0, 12] + " {{",
      "artifact must not embed the raw template source"
  end

  def test_error_messages_identical_without_source
    template = compile("A{{ 'x' | truncate: 1.5 }}B")
    blob = template.to_artifact
    restored = LiquidIL::Artifact.load(blob)
    assert_equal template.render({}), restored.render({})
    assert_includes restored.render({}), "Liquid error (line 1): invalid integer"
  end

  def test_stale_ruby_stamp_raises
    blob = compile("hi").to_artifact
    # Corrupt the stamp: bump the first stamp byte
    stamp_pos = 4 + 1 + 1
    bad = blob.dup
    bad.setbyte(stamp_pos, bad.getbyte(stamp_pos) + 1)
    assert_raises(LiquidIL::StaleArtifactError) { LiquidIL::Artifact.load(bad) }
  end

  def test_unknown_version_raises_stale
    blob = compile("hi").to_artifact
    bad = blob.dup
    bad.setbyte(4, 99)
    assert_raises(LiquidIL::StaleArtifactError) { LiquidIL::Artifact.load(bad) }
  end

  def test_corrupted_iseq_raises_instead_of_loading
    blob = compile("hello {{ v }}").to_artifact
    bad = blob.dup
    bad.setbyte(bad.bytesize - 10, bad.getbyte(bad.bytesize - 10) ^ 0xFF)
    assert_raises(LiquidIL::CorruptArtifactError) { LiquidIL::Artifact.load(bad) }
  end

  def test_truncated_artifact_raises
    blob = compile("hello {{ v }}").to_artifact
    assert_raises(LiquidIL::CorruptArtifactError) { LiquidIL::Artifact.load(blob.byteslice(0, blob.bytesize / 2)) }
  end

  def test_legacy_marshal_payload_still_loads
    template = compile("Hello {{ name }}!")
    legacy_blob = Marshal.dump(template.cache_data)
    restored = LiquidIL::Artifact.load(legacy_blob)
    assert_equal "Hello World!", restored.render("name" => "World")
  end

  def test_write_cache_load_cache_roundtrip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.ilc")
      template = compile("{{ a }}+{{ b }}")
      template.write_cache(path)
      blob = File.binread(path)
      assert LiquidIL::Artifact.artifact?(blob)
      restored = LiquidIL::Template.load_cache(path)
      assert_equal "1+2", restored.render("a" => 1, "b" => 2)
    end
  end

  def test_artifact_render_matches_fresh_render_with_loops_and_filters
    src = "{% for p in ps %}{{ p.name | upcase }}:{{ p.price | times: 2 }} {% endfor %}"
    template = compile(src)
    restored = LiquidIL::Artifact.load(template.to_artifact)
    assigns = { "ps" => [{ "name" => "a", "price" => 3 }, { "name" => "b", "price" => 4 }] }
    assert_equal template.render(assigns), restored.render(assigns)
  end
end
