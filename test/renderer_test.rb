# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require_relative "../lib/liquid_il"

class RendererTest < Minitest::Test
  class Source
    attr_reader :reads

    def initialize(files)
      @files = files
      @reads = Hash.new(0)
    end

    def set(name, body)
      @files[name] = body
    end

    def digest(name)
      body = @files[name]
      body && Digest::SHA256.hexdigest(body)
    end

    def bytesize(name)
      @files[name]&.bytesize
    end

    def read(name)
      @reads[name] += 1
      @files[name]
    end
  end

  class RailsCache
    attr_reader :reads, :writes, :read_multi_calls

    def initialize
      @data = {}
      reset_stats!
    end

    def read(key)
      @reads += 1
      @data[key]
    end

    def write(key, value, **)
      @writes += 1
      @data[key] = value
      true
    end

    def read_multi(*keys)
      @read_multi_calls += 1
      keys.to_h { |key| [key, @data[key]] if @data.key?(key) }.compact
    end

    def reset_stats!
      @reads = 0
      @writes = 0
      @read_multi_calls = 0
    end
  end

  class HostFilterScope < LiquidIL::Scope
    def initialize(...)
      super
      self.prefer_custom_filters = true
    end

    def custom_filter?(_name)
      true
    end

    def apply_custom_filter(name, input, args)
      "host-#{name}(#{([input] + args).join(',')})"
    end
  end

  class HostErrorScope < LiquidIL::Scope
    attr_reader :handled_error

    def lookup(_key)
      raise LiquidIL::RuntimeError.new("host lookup failed", line: 1)
    end

    def handle_render_error(error, output: nil)
      @handled_error = error
      output ? output << "host-handled" : "host-handled"
    end
  end

  class HostTagScope < LiquidIL::Scope
    attr_reader :calls

    def initialize(...)
      super
      @calls = []
    end

    def render_host_tag(slot, source_id:, template_name:, name:, line:, output:)
      @calls << {
        slot: slot,
        source_id: source_id,
        template_name: template_name,
        name: name,
        line: line,
      }
      output << "[host:#{slot}]"
    end
  end

  SMALL = "<b>{{ title }}</b>"
  LARGE = "<section>#{"x" * 700} {{ title | upcase }}</section>"
  LAYOUT = "{% render 'small', title: title %}|{% render 'large', title: title %}"

  def setup
    @source = Source.new("layout" => LAYOUT, "small" => SMALL, "large" => LARGE)
    @remote = RailsCache.new
    @events = []
    @renderer = renderer
  end

  def renderer
    LiquidIL::Renderer.new(
      remote_cache: @remote,
      namespace: "renderer-test:v1",
      instrumenter: ->(name, payload) { @events << [name, payload] },
    )
  end

  def expected(small: SMALL, large_letter: "X")
    "<b>Ada</b>|<section>#{large_letter.downcase * 700} ADA</section>"
  end

  def test_cold_remote_and_local_lru_paths_render_named_templates
    cold = @renderer.session(templates: @source) do |session|
      session.render("layout", "title" => "Ada")
    end
    assert_equal expected, cold
    assert_equal({ "layout" => 1, "small" => 1, "large" => 1 }, @source.reads)
    assert_operator @remote.writes, :>=, 4

    reads_before = @remote.reads
    source_reads_before = @source.reads.dup
    hot = @renderer.session(templates: @source) do |session|
      # The individually fetched template is bound to the same partial provider.
      session.fetch("layout").render("title" => "Ada")
    end
    assert_equal expected, hot
    assert_equal reads_before, @remote.reads, "loaded-proc LRU hit must avoid remote cache"
    assert_equal source_reads_before, @source.reads, "loaded-proc LRU hit must avoid body reads"

    fresh = renderer
    @remote.reset_stats!
    source_reads_before = @source.reads.dup
    remote = fresh.session(templates: @source) do |session|
      session.render("layout", "title" => "Ada")
    end
    assert_equal expected, remote
    assert_equal source_reads_before, @source.reads, "remote artifact hit must avoid body reads"
    assert_operator @remote.reads, :>=, 4
  end

  def test_small_partial_edit_invalidates_entry_but_large_partial_versions_independently
    @renderer.session(templates: @source) { |s| s.render("layout", "title" => "Ada") }

    @source.set("small", "<i>{{ title }}</i>")
    reads_before = @source.reads.dup
    output = @renderer.session(templates: @source) { |s| s.render("layout", "title" => "Ada") }
    assert_includes output, "<i>Ada</i>"
    assert_operator @source.reads["layout"], :>, reads_before["layout"],
      "an inlined dependency edit recompiles the entry"
    assert_operator @source.reads["small"], :>, reads_before["small"]
    assert_equal reads_before["large"], @source.reads["large"],
      "unchanged external partial stays in its own loaded artifact"

    @source.set("large", "<section>#{"z" * 700} {{ title | downcase }}</section>")
    reads_before = @source.reads.dup
    output = @renderer.session(templates: @source) { |s| s.render("layout", "title" => "ADA") }
    assert_includes output, "#{"z" * 700} ada"
    assert_equal reads_before["layout"], @source.reads["layout"],
      "external dependency edit must not recompile the entry"
    assert_equal reads_before["small"], @source.reads["small"]
    assert_operator @source.reads["large"], :>, reads_before["large"],
      "only the edited external partial recompiles lazily"
  end

  def test_crossing_inline_threshold_replans_the_entry
    @renderer.session(templates: @source) { |s| s.render("layout", "title" => "Ada") }
    reads_before = @source.reads.dup
    @source.set("small", "<em>#{"s" * 700} {{ title }}</em>")

    output = @renderer.session(templates: @source) { |s| s.render("layout", "title" => "Ada") }

    assert_includes output, "#{"s" * 700} Ada"
    assert_operator @source.reads["layout"], :>, reads_before["layout"],
      "inline-to-external classification change must rebuild the caller"
    assert_operator @source.reads["small"], :>, reads_before["small"],
      "new external artifact compiles when its call site executes"
  end

  def test_preload_key_batches_entry_and_external_partial_cache_reads
    @renderer.session(templates: @source, preload_key: "route:product") do |session|
      session.render("layout", "title" => "Ada")
    end

    fresh = renderer
    @remote.reset_stats!
    source_reads_before = @source.reads.dup
    stats = nil
    output = fresh.session(templates: @source, preload_key: "route:product") do |session|
      result = session.render("layout", "title" => "Ada")
      stats = session.stats
      result
    end

    assert_equal expected, output
    assert_equal source_reads_before, @source.reads
    assert_equal 1, @remote.read_multi_calls
    assert_operator stats[:preload_keys], :>=, 4
    assert @events.any? { |name, payload| name == "liquid_il.cache.lookup" && payload.key?(:hit) },
      "every cache tier should be available to telemetry"
  end

  def test_session_template_can_render_to_a_host_scope_and_output_buffer
    renderer = LiquidIL::Renderer.new(
      namespace: "renderer-test:host-scope",
      context_options: { prefer_custom_filters: true },
    )
    source = Source.new("template" => "{{ title | upcase }}")
    scope = HostFilterScope.new({ "title" => "Ada" })
    output = +"prefix:"

    renderer.session(templates: source) do |session|
      returned = session.fetch("template").render_scope(scope, output: output)

      assert_same output, returned
      assert_equal "prefix:host-upcase(Ada)", output
    end
  end

  def test_host_scope_can_handle_render_errors
    renderer = LiquidIL::Renderer.new(namespace: "renderer-test:host-errors")
    source = Source.new("template" => "{{ value }}")
    scope = HostErrorScope.new
    output = +"prefix:"

    renderer.session(templates: source) do |session|
      returned = session.fetch("template").render_scope(scope, output: output)

      assert_same output, returned
      assert_equal "prefix:host-handled", output
      assert_instance_of LiquidIL::RuntimeError, scope.handled_error
    end
  end

  def test_registered_host_tags_compile_to_source_local_slots
    LiquidIL::Tags.register_host("renderer_host", end_tag: "endrenderer_host")
    source_body = <<~LIQUID
      before
      {% renderer_host %}opaque {{ ignored }}{% endrenderer_host %}
      {% liquid
        renderer_host
        endrenderer_host
      %}
      after
    LIQUID
    renderer = LiquidIL::Renderer.new(namespace: "renderer-test:host-tag")
    source = Source.new("template" => source_body)
    scope = HostTagScope.new

    output = renderer.session(templates: source) do |session|
      session.fetch("template").render_scope(scope)
    end

    assert_equal "before\n[host:0]\n[host:1]\nafter\n", output
    assert_equal [0, 1], scope.calls.map { |call| call[:slot] }
    assert_equal [Digest::SHA256.hexdigest(source_body)], scope.calls.map { |call| call[:source_id] }.uniq
    assert_equal ["template"], scope.calls.map { |call| call[:template_name] }.uniq
    assert_equal ["renderer_host"], scope.calls.map { |call| call[:name] }.uniq
  end
end
