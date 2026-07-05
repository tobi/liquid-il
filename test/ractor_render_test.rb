# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

class RactorRenderTest < Minitest::Test
  class FS
    def initialize(templates)
      @templates = templates
    end

    def read_template_file(name, _context = nil)
      @templates[name.to_s]
    end
  end

  def setup
    skip "Ractor is not available on this Ruby" unless defined?(Ractor)
  end

  def test_artifact_bytes_load_and_render_inside_ractors
    partials = {
      "card" => "P{{ value | upcase }}:{% for tag in tags %}{{ tag | capitalize }}{% endfor %}",
    }
    ctx = LiquidIL::Context.new(file_system: FS.new(partials))
    template = ctx.parse(<<~LIQUID)
      {% assign name = "zed" -%}
      {% capture banner %}B{{ name | upcase }}{% endcapture -%}
      {{ banner }}|
      {%- for item in items -%}
        {{ forloop.index }}={{ item.name | upcase }}:{% cycle "odd","even" %};
      {%- endfor -%}
      |{% render "card", value: name, tags: tags %}
    LIQUID
    env = {
      "items" => [{ "name" => "hat" }, { "name" => "bag" }, { "name" => "pin" }],
      "tags" => %w[new sale],
    }
    expected = template.render(env)
    artifact = template.to_artifact.freeze
    Ractor.make_shareable(artifact)

    ractors = 4.times.map do
      Ractor.new(artifact) do |bytes|
        $VERBOSE = nil
        require "liquid_il"
        assigns = {
          "items" => [{ "name" => "hat" }, { "name" => "bag" }, { "name" => "pin" }],
          "tags" => %w[new sale],
        }
        LiquidIL.load_artifact(bytes).render(assigns)
      end
    end

    assert_equal [expected] * 4, ractors.map(&:value)
  end

  def test_dynamic_include_render_time_compilation_is_excluded_from_ractor_v1
    fs_source = { "card" => "P{{ x }}" }.freeze
    template = LiquidIL.parse("{% include partial_name %}")
    artifact = template.to_artifact.freeze
    Ractor.make_shareable(artifact)
    Ractor.make_shareable(fs_source)

    ractor = Ractor.new(artifact, fs_source) do |bytes, files|
      $VERBOSE = nil
      require "liquid_il"
      fs = Object.new
      fs.define_singleton_method(:read_template_file) { |name, _context = nil| files[name.to_s] }
      LiquidIL.load_artifact(bytes).render!(
        { "partial_name" => "card", "x" => 7 },
        registers: { "file_system" => fs }
      )
    rescue => e
      [e.class.name, e.message]
    end

    error_class, message = ractor.value
    assert_includes error_class, "Ractor"
    assert_match(/class variables|instance variables|non-main Ractors|unshareable/i, message)
  end
end
