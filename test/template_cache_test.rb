# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# LiquidIL.load_artifact / load_and_render and the memory-bounded LRU cache.
class TemplateCacheTest < Minitest::Test
  def blob_for(source)
    LiquidIL::Template.parse(source).to_artifact
  end

  def test_load_artifact_renders
    artifact = LiquidIL.load_artifact(blob_for("Hello {{ name }}!"))
    assert_instance_of LiquidIL::CompiledArtifact, artifact
    assert_equal "Hello World!", artifact.render("name" => "World")
    assert_operator artifact.byte_size, :>, 0
  end

  def test_load_and_render_one_shot
    assert_equal "6", LiquidIL.load_and_render(blob_for("{{ a | plus: b }}"), { "a" => 2, "b" => 4 })
  end

  def test_load_and_render_output_matches_template_render
    src = "{% for x in xs %}{{ x | upcase }}-{% endfor %}"
    template = LiquidIL::Template.parse(src)
    assigns = { "xs" => %w[a b c] }
    assert_equal template.render(assigns), LiquidIL.load_and_render(template.to_artifact, assigns)
  end

  def test_cache_loads_once_and_reuses
    cache = LiquidIL::TemplateCache.new(max_bytes: 1024 * 1024)
    blob = blob_for("V={{ v }}")
    assert_equal "V=1", cache.render("k", blob, "v" => 1)
    first = cache.fetch("k", blob)
    assert_equal "V=2", cache.render("k", blob, "v" => 2)
    assert_same first, cache.fetch("k", blob), "same loaded artifact must be reused"
    assert_equal 1, cache.size
  end

  def test_cache_fetch_with_lazy_block
    cache = LiquidIL::TemplateCache.new(max_bytes: 1024 * 1024)
    calls = 0
    loader = -> { calls += 1; blob_for("X{{ v }}") }
    assert_equal "X1", cache.fetch("k") { loader.call }.render("v" => 1)
    assert_equal "X2", cache.fetch("k") { loader.call }.render("v" => 2)
    assert_equal 1, calls, "loader must only run on the miss"
  end

  def test_cache_reloads_when_blob_content_changes
    cache = LiquidIL::TemplateCache.new(max_bytes: 1024 * 1024)
    assert_equal "one", cache.render("k", blob_for("one"), {})
    assert_equal "two", cache.render("k", blob_for("two"), {})
    assert_equal 1, cache.size
  end

  def test_cache_evicts_least_recently_used_over_budget
    blobs = ("a".."e").map { |c| [c, blob_for("template #{c} {{ v }}")] }
    per = blobs[0][1].bytesize
    cache = LiquidIL::TemplateCache.new(max_bytes: per * 3 + 10)

    blobs.first(3).each { |k, b| cache.render(k, b, "v" => 1) }
    assert_equal 3, cache.size

    # Touch "a" so "b" becomes least recently used, then insert "d"
    cache.fetch("a", blobs[0][1])
    cache.render("d", blobs[3][1], "v" => 1)
    assert_equal 3, cache.size
    assert_operator cache.bytes, :<=, cache.max_bytes

    # "b" was evicted: fetching without a blob or block raises
    assert_raises(ArgumentError) { cache.fetch("b") }
    # "a" survived (recently used)
    assert_equal LiquidIL::CompiledArtifact, cache.fetch("a").class
  end

  def test_oversized_artifact_renders_but_is_not_retained
    blob = blob_for("big {{ v }}")
    cache = LiquidIL::TemplateCache.new(max_bytes: 10)
    assert_equal "big 1", cache.render("k", blob, "v" => 1)
    assert_equal 0, cache.size
    assert_equal 0, cache.bytes
  end

  def test_artifact_render_supports_registers_file_system
    fs = Object.new
    fs.define_singleton_method(:read_template_file) { |name, _ctx = nil| "P[{{ x }}]" }
    ctx = LiquidIL::Context.new(file_system: fs)
    blob = ctx.parse("{% assign t = 'p' %}{% include t %}").to_artifact
    out = LiquidIL.load_artifact(blob).render({ "x" => 7 }, registers: { "file_system" => fs })
    assert_equal "P[7]", out
  end
end
