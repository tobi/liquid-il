# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# The artifact self-consistency invariant: for ANY (template, environment,
# filesystem), a DIRECT render must equal the to_artifact -> load -> render
# roundtrip, byte-for-byte -- including error-path outputs.
#
# A loaded artifact carries no Context, so its file_system has to be threaded
# in at render time via registers[:file_system] (Template.render and
# CompiledArtifact.render both read it). The differential fuzzer once caught
# this being dropped on the load side, which collapsed every {% render %} /
# {% include %} -- including missing-partial and syntax-error-partial error
# paths -- into "This liquid context does not allow includes." These tests
# lock the invariant across both load paths (Artifact.load -> Template and
# LiquidIL.load_artifact -> CompiledArtifact).
class ArtifactSelfConsistencyTest < Minitest::Test
  # Minimal name => source filesystem, matching the shape LiquidIL expects
  # (read_template_file(name, context=nil)); a missing name raises like a
  # real asset store.
  class MemoryFS
    def initialize(files) = @files = files
    def read_template_file(name, _context = nil)
      @files[name] || raise("Could not find asset #{name}")
    end
  end

  # Renders (template, env, fs) three ways and asserts all three agree:
  #   1. direct       -- Context-backed Template.render
  #   2. template     -- Artifact.load(blob).render(registers: file_system)
  #   3. compiled     -- LiquidIL.load_artifact(blob).render(registers: file_system)
  # Returns the direct output so callers can additionally pin the exact string.
  def assert_roundtrips(src, files: {}, env: {})
    fs = MemoryFS.new(files)
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse(src)

    direct = template.render({}, static_environments: env, render_errors: true)

    blob = template.to_artifact
    regs = { file_system: fs }
    via_template = LiquidIL::Artifact.load(blob)
      .render({}, static_environments: env, render_errors: true, registers: regs)
    via_compiled = LiquidIL.load_artifact(blob)
      .render({}, static_environments: env, render_errors: true, registers: regs)

    assert_equal direct, via_template,
      "Artifact.load roundtrip diverged from direct render for #{src.inspect}"
    assert_equal direct, via_compiled,
      "load_artifact roundtrip diverged from direct render for #{src.inspect}"
    direct
  end

  def test_static_partial_roundtrips
    out = assert_roundtrips('[{% include "greet" %}]',
      files: { "greet" => "Hi {{ who }}" }, env: { "who" => "Sam" })
    assert_equal "[Hi Sam]", out
  end

  def test_static_render_roundtrips
    out = assert_roundtrips('[{% render "greet" %}]',
      files: { "greet" => "Hi {{ who }}" }, env: { "who" => "Sam" })
    # render is isolated: assigns/locals do not leak in, but static_environments do.
    assert_equal "[Hi Sam]", out
  end

  def test_missing_partial_roundtrips
    out = assert_roundtrips('[{% include "missing" %}]', files: { "greet" => "x" })
    assert_equal "[Liquid error (line 1): Could not find asset missing]", out
  end

  def test_syntax_error_partial_roundtrips
    out = assert_roundtrips('[{% render "bad" %}]', files: { "bad" => '{{ "unterminated' })
    assert_includes out, "Liquid syntax error (bad line 1):"
  end

  def test_dynamic_name_partial_from_environment_roundtrips
    out = assert_roundtrips('[{% include tpl %}]',
      files: { "p" => "P<{{ who }}>" }, env: { "tpl" => "p", "who" => "Zed" })
    assert_equal "[P<Zed>]", out
  end

  def test_dynamic_name_partial_from_assign_roundtrips
    out = assert_roundtrips("{% assign t = 'p' %}[{% include t %}]",
      files: { "p" => "P<{{ x }}>" }, env: { "x" => 7 })
    assert_equal "[P<7>]", out
  end

  def test_include_with_break_interrupt_roundtrips
    # include shares scope and propagates interrupts to the enclosing loop:
    # the partial breaks at i == 2, so only "1" is emitted. The interrupt must
    # cross the artifact boundary identically.
    out = assert_roundtrips(
      '{% for i in seq %}{% include "brk" %}{{ i }}{% endfor %}',
      files: { "brk" => "{% if i == 2 %}{% break %}{% endif %}" },
      env: { "seq" => [1, 2, 3] })
    assert_equal "1", out
  end

  def test_include_with_continue_interrupt_roundtrips
    out = assert_roundtrips(
      '{% for i in seq %}{% include "skip" %}{{ i }}{% endfor %}',
      files: { "skip" => "{% if i == 2 %}{% continue %}{% endif %}" },
      env: { "seq" => [1, 2, 3] })
    assert_equal "13", out
  end

  # Regression pin for the two differential-fuzzer findings this file replaces
  # (fuzz/findings/artifact_self_consistency/{1d217bf59027,91f5377ca45d}.yml):
  # both were error-path partials whose loaded-artifact render lost the
  # file_system and reported the includes-not-allowed error instead.
  def test_fuzz_findings_regression
    assert_equal "Liquid error (line 1): Could not find asset footer",
      assert_roundtrips('{% include "footer" %}')

    out = assert_roundtrips('{% render "aside" %}',
      files: { "aside" => '{{ nil }}{% case -0.5 %}{% when "a" %}{{ "{{ x' })
    assert_includes out, "Liquid syntax error (aside line 1):"
  end
end
