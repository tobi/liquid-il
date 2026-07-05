# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# External partial references (the lazy-partial model). When a partial_index is
# supplied alongside/instead of a file_system, large or opaque partials become
# EXTERNAL provider call sites instead of being fetched+inlined at compile time;
# a PartialProvider supplies their compiled artifacts at render time.
class ExternalPartialsTest < Minitest::Test
  # A digest index that records which names it was asked about. Reports a
  # content digest and a bytesize per partial WITHOUT any body.
  class SpyIndex
    attr_reader :digest_calls, :bytesize_calls

    def initialize(map) # name => [digest, bytesize]
      @map = map
      @digest_calls = []
      @bytesize_calls = []
    end

    def digest(name)
      @digest_calls << name
      @map[name]&.first
    end

    def bytesize(name)
      @bytesize_calls << name
      @map[name]&.last
    end
  end

  # A file system that records every body fetch (read_template_file).
  class SpyFS
    attr_reader :reads

    def initialize(bodies)
      @bodies = bodies
      @reads = []
    end

    def read_template_file(name, _context = nil)
      @reads << name
      @bodies[name.to_s]
    end
  end

  BIG1 = "BIG1[#{"x" * 800}]{{ a }}"
  BIG2 = "BIG2[#{"y" * 800}]{{ b }}"
  SMALL = "S<{{ c }}>"
  BODIES = { "big1" => BIG1, "big2" => BIG2, "small" => SMALL }.freeze
  TMPL = "P{% render 'big1', a: 1 %}|{% render 'small', c: 3 %}|{% render 'big2', b: 2 %}Q"

  def build_index
    SpyIndex.new(
      "big1" => ["d-big1", BIG1.bytesize],
      "big2" => ["d-big2", BIG2.bytesize],
      "small" => ["d-small", SMALL.bytesize],
    )
  end

  # A provider that compiles each requested body into its own artifact.
  def artifact_provider(bodies, calls: nil)
    lambda do |name, digest|
      calls << [name, digest] if calls
      src = bodies[name]
      src ? LiquidIL::Compiler::Ruby.compile(src) : nil
    end
  end

  def test_large_partials_not_fetched_at_compile_but_render_correctly
    index = build_index
    fs = SpyFS.new(BODIES)
    ctx = LiquidIL::Context.new(file_system: fs, partial_index: index)
    template = ctx.parse(TMPL)

    # The two large bodies are NEVER fetched; the small one is fetched+inlined.
    refute_includes fs.reads, "big1"
    refute_includes fs.reads, "big2"
    assert_includes fs.reads, "small"

    deps = template.partial_dependencies
    assert_equal :external, deps["big1"][:disposition]
    assert_equal :external, deps["big2"][:disposition]
    assert_equal :inline, deps["small"][:disposition]
    assert_equal "d-big1", deps["big1"][:digest]

    calls = []
    out = template.render({ "a" => "A", "b" => "B", "c" => "C" },
                          partial_provider: artifact_provider(BODIES, calls: calls))
    assert_equal [["big1", "d-big1"], ["big2", "d-big2"]].sort, calls.sort

    # Renders identically to the all-inline compile of the same template.
    inline = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL)
    assert_equal inline.render({ "a" => "A", "b" => "B", "c" => "C" }), out
  end

  def test_cold_provider_laziness_dead_branch_never_fetches
    index = SpyIndex.new("big" => ["d-big", 5000])
    fs = SpyFS.new("big" => "BIG{{x}}")
    calls = []
    ctx = LiquidIL::Context.new(file_system: fs, partial_index: index)
    template = ctx.parse("{% if false %}{% render 'big' %}{% endif %}DONE")

    out = template.render({}, partial_provider: artifact_provider({ "big" => "BIG{{x}}" }, calls: calls))
    assert_equal "DONE", out
    assert_empty calls, "provider must not be asked for a partial whose call site never runs"
    assert_empty fs.reads, "file_system must not be read for a dead render"
  end

  def test_include_reads_caller_scope_through_external_boundary
    bodies = { "inc" => "[x={{ x }} item={{ item }}]" }
    index = SpyIndex.new("inc" => ["d-inc", 5000])
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
    template = ctx.parse("{% assign x = 'HELLO' %}{% include 'inc' %}")

    out = template.render({}, partial_provider: artifact_provider(bodies))
    assert_equal "[x=HELLO item=]", out
  end

  def test_break_propagation_through_external_include
    bodies = { "brk" => "A{% break %}B" }
    index = SpyIndex.new("brk" => ["d-brk", 5000])
    src = "{% for i in (1..3) %}X{% include 'brk' %}Y{% endfor %}Z"

    external = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
      .parse(src).render({}, partial_provider: artifact_provider(bodies))
    inline = LiquidIL::Context.new(file_system: SpyFS.new(bodies)).parse(src).render({})

    assert_equal "XAZ", inline
    assert_equal inline, external
  end

  def test_continue_propagation_through_external_include
    bodies = { "cont" => "A{% continue %}B" }
    index = SpyIndex.new("cont" => ["d-cont", 5000])
    src = "{% for i in (1..3) %}X{% include 'cont' %}Y{% endfor %}Z"

    external = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
      .parse(src).render({}, partial_provider: artifact_provider(bodies))
    inline = LiquidIL::Context.new(file_system: SpyFS.new(bodies)).parse(src).render({})
    assert_equal inline, external
  end

  def test_missing_from_provider_falls_back_to_file_system
    bodies = { "ext" => "FS-BODY{{v}}" }
    index = SpyIndex.new("ext" => ["d-ext", 5000])
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
    template = ctx.parse("{% render 'ext', v: 9 %}")

    empty_provider = ->(_name, _digest) { nil }
    assert_equal "FS-BODY9", template.render({}, partial_provider: empty_provider)
  end

  def test_missing_everywhere_matches_todays_error_text
    index = SpyIndex.new("gone" => ["d-gone", 5000])
    external = LiquidIL::Context.new(file_system: SpyFS.new({}), partial_index: index)
      .parse("{% render 'gone' %}").render({}, partial_provider: ->(_n, _d) { nil })
    today = LiquidIL::Context.new(file_system: SpyFS.new({}))
      .parse("{% render 'gone' %}").render({})
    assert_equal today, external
  end

  def test_render_to_output_buffer_appends_and_equals_render
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(BODIES))
    template = ctx.parse(TMPL)
    assigns = { "a" => "A", "b" => "B", "c" => "C" }

    buf = +"PREFIX-"
    ret = template.render_to_output_buffer(assigns, buf)
    assert_same buf, ret
    assert_equal "PREFIX-#{template.render(assigns)}", buf
  end

  def test_render_to_output_buffer_on_loaded_artifact
    blob = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL).to_artifact
    artifact = LiquidIL.load_artifact(blob)
    assigns = { "a" => "A", "b" => "B", "c" => "C" }

    buf = +"HEAD"
    ret = artifact.render_to_output_buffer(assigns, buf)
    assert_same buf, ret
    assert_equal "HEAD#{artifact.render(assigns)}", buf
  end

  def test_artifact_roundtrip_exposes_external_deps_and_renders
    index = build_index
    template = LiquidIL::Context.new(file_system: SpyFS.new(BODIES), partial_index: index).parse(TMPL)
    blob = template.to_artifact
    loaded = LiquidIL.load_artifact(blob)

    # Only the external entries are persisted (host prefetch list).
    assert_equal %w[big1 big2].sort, loaded.partial_dependencies.keys.sort
    loaded.partial_dependencies.each_value { |info| assert_equal :external, info[:disposition] }

    assigns = { "a" => "A", "b" => "B", "c" => "C" }
    inline = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL).render(assigns)
    assert_equal inline, loaded.render(assigns, partial_provider: artifact_provider(BODIES))
  end

  def test_no_partial_index_is_byte_identical_and_unchanged
    # Compiling the same template with and without an all-external index yields
    # the SAME bytes only when no index is supplied — index mode changes bytes
    # (external call sites) but the plain path must be untouched.
    plain_a = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL).to_artifact
    plain_b = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL).to_artifact
    assert_equal plain_a.bytesize, plain_b.bytesize
    assert_equal plain_a, plain_b

    # partial_dependencies still populated for the plain path (inline/lambda).
    plain = LiquidIL::Context.new(file_system: SpyFS.new(BODIES)).parse(TMPL)
    assert_equal :inline, plain.partial_dependencies["small"][:disposition]
  end

  def test_digest_only_index_externalizes_everything
    # An index that answers only digest() (no bytesize/inline?/external?) makes
    # every known partial external — the body is not available without a fetch.
    index = Class.new do
      def digest(name)
        { "p" => "d-p" }[name]
      end
    end.new
    fs = SpyFS.new("p" => "PBODY{{v}}")
    ctx = LiquidIL::Context.new(file_system: fs, partial_index: index)
    template = ctx.parse("{% render 'p', v: 1 %}")

    assert_equal :external, template.partial_dependencies["p"][:disposition]
    assert_empty fs.reads
    assert_equal "PBODY1", template.render({}, partial_provider: ->(_n, _d) { LiquidIL::Compiler::Ruby.compile("PBODY{{v}}") })
  end

  def test_external_render_for_collection
    bodies = { "card" => "[{{ item }}]" }
    index = SpyIndex.new("card" => ["d-card", 5000])
    src = "{% render 'card' for items %}"
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
    external = ctx.parse(src).render({ "items" => [1, 2, 3] }, partial_provider: artifact_provider(bodies))
    inline = LiquidIL::Context.new(file_system: SpyFS.new(bodies)).parse(src).render({ "items" => [1, 2, 3] })
    assert_equal inline, external
  end

  def test_external_render_with_value
    bodies = { "box" => "<{{ box }}>" }
    index = SpyIndex.new("box" => ["d-box", 5000])
    src = "{% render 'box' with thing %}"
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
    external = ctx.parse(src).render({ "thing" => "V" }, partial_provider: artifact_provider(bodies))
    inline = LiquidIL::Context.new(file_system: SpyFS.new(bodies)).parse(src).render({ "thing" => "V" })
    assert_equal inline, external
  end

  def test_provider_via_registers
    bodies = { "r" => "R{{v}}" }
    index = SpyIndex.new("r" => ["d-r", 5000])
    ctx = LiquidIL::Context.new(file_system: SpyFS.new(bodies), partial_index: index)
    template = ctx.parse("{% render 'r', v: 7 %}")
    out = template.render({}, registers: { "partial_provider" => artifact_provider(bodies) })
    assert_equal "R7", out
  end
end
