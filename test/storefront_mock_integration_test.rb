# frozen_string_literal: true

require "minitest/autorun"
require_relative "../integration/storefront_mock/lib/storefront_mock"

# End-to-end proof of the storefront integration design: adapter stack +
# ScopeShim + CompiledTemplateCache (preload -> memoized -> tiered KV -> compile)
# + in-process live-proc tier, with the reference `liquid` gem as the
# byte-for-byte conformance oracle. Time-boxed well under 10s.
class StorefrontMockIntegrationTest < Minitest::Test
  include StorefrontMock

  # Standard-Liquid-only templates so BOTH engines agree byte-for-byte (this is
  # the verifier's conformance gate for the mock's tag/filter surface).
  LAYOUT = <<~LIQ
    <html>
    {% render 'header', title: title %}
    <ul>{% for p in products %}{% render 'card', product: p %}{% endfor %}</ul>
    {% render 'promo' %}
    </html>
  LIQ
  HEADER = "<h1>{{ title | upcase }}</h1>"
  CARD   = "<li>{{ product.title }} — {{ product.price | times: 100 }}c</li>"
  PROMO  = "<aside>Free shipping over {{ 50 }}!</aside>"
  FOOTER = "<small>{{ 'shop' | upcase }} © {{ year }}</small>"
  PAGE   = "<footer>{% render 'footer' %}</footer>"

  ASSIGNS = {
    "title" => "Acme Goods",
    "year" => 2026,
    "products" => [
      { "title" => "Widget", "price" => 3 },
      { "title" => "Gadget", "price" => 5 },
      { "title" => "Gizmo",  "price" => 8 },
    ],
  }.freeze

  def build_theme(fleet, id)
    theme = fleet.new_theme(id)
    theme.set_asset("layout", LAYOUT)
    theme.set_asset("header", HEADER)
    theme.set_asset("card",   CARD)
    theme.set_asset("promo",  PROMO)
    theme.set_asset("footer", FOOTER)
    theme.set_asset("page",   PAGE)
    theme
  end

  def ctx(shop: nil, self_verify: nil)
    MockLiquidContext.new(assigns: deep_dup(ASSIGNS), shop: shop, self_verify_features: self_verify)
  end

  def deep_dup(obj)
    Marshal.load(Marshal.dump(obj))
  end

  def micros
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond) - t0
  end

  # ---------------------------------------------------------------------------
  # The headline scenario (steps a–f), with per-step timings printed.
  # ---------------------------------------------------------------------------
  def test_end_to_end_storefront_scenario
    fleet = Fleet.new
    theme = build_theme(fleet, "shop-1")
    layout = EntryRef.new(theme, "layout")
    fp = "route:index"

    timings = {}

    # --- control oracle (reference liquid), rendered fresh each request ---
    control_proc = fleet.spawn_process
    control_out, = control_proc.render_request(control_proc.ruby_adapter, layout, ctx)
    timings[:control_parse_render] = micros do
      control_proc.render_request(control_proc.ruby_adapter, layout, ctx)
    end

    # === (a) Request 1 — cold fleet: compile on miss, artifacts to KV ========
    p1 = fleet.spawn_process
    fleet.bodies.reset_fetches!
    out1 = nil
    ev1 = nil
    timings[:cold_compile_render] = micros do
      out1, ev1 = p1.render_request(p1.il_adapter, layout, ctx, fingerprint_key: fp)
    end

    assert_equal 1, ev1[:compile], "request 1 must compile on a cold miss"
    assert_equal 0, ev1[:store_hit]
    # only the four assets in the layout tree were fetched (lazy: nothing else)
    assert_equal 4, fleet.bodies.fetch_count, "cold compile fetches only referenced bodies"
    assert control_proc.store.remote.writes.positive?
    # artifact + manifest + fingerprint all landed in the shared remote KV
    assert fleet.remote.key?("fpx:liquid-il:#{fp}"), "fingerprint saved for next request"
    assert_equal control_out, out1, "(f) cold IL output byte-identical to reference"

    # === (b) Request 2 — another process, same KV: preload, ZERO compiles ====
    p2 = fleet.spawn_process
    p2.store.reset_stats!
    fleet.bodies.reset_fetches!
    out2 = nil
    ev2 = nil
    timings[:remote_hit_load_render] = micros do
      out2, ev2 = p2.render_request(p2.il_adapter, layout, ctx, fingerprint_key: fp)
    end

    assert_equal 0, ev2[:compile], "request 2 must NOT compile — artifact is in KV"
    assert_operator ev2[:store_hit], :>=, 1, "request 2 loads the artifact from the store"
    assert_equal 0, fleet.bodies.fetch_count, "loaded artifact needs no body fetches"
    assert_operator p2.store.remote.reads, :>, 0, "cold node-local pulls from remote once"
    assert_equal out1, out2
    assert_equal control_out, out2, "(f) remote-hit output byte-identical to reference"

    # === (c) Request 3 — same process, hot: live-proc tier, ZERO KV reads ====
    p2.store.reset_stats!
    out3 = nil
    ev3 = nil
    n = 200
    total = micros do
      n.times { out3, ev3 = p2.render_request(p2.il_adapter, layout, ctx) }
    end
    timings[:live_proc_render] = total / n

    assert_equal 0, p2.store.total_reads, "(c) hot render touches NO KV — served by live proc"
    assert_equal 0, ev3[:compile]
    assert_equal 0, ev3[:store_hit], "no artifact load either — the proc is resident"
    assert_equal out1, out3
    assert_equal control_out, out3, "(f) live-proc output byte-identical to reference"

    print_timings(timings)

    # === (d) Theme edit — one snippet body changes, content-addressed ========
    key_before = composite_key(theme, "layout")
    card_before = theme.digest_for("card")
    header_before = theme.digest_for("header")
    theme.set_asset("card", "<li>#{'%'} {{ product.title }} is {{ product.price }} dollars</li>")
    refute_equal card_before, theme.digest_for("card"), "edited snippet re-hashes"
    assert_equal header_before, theme.digest_for("header"), "untouched snippet keeps its digest"
    key_after = composite_key(theme, "layout")
    refute_equal key_before, key_after, "(d) only the affected entry's composite key changes"

    p3 = fleet.spawn_process
    _, ev_layout = p3.render_request(p3.il_adapter, layout, ctx, fingerprint_key: fp)
    assert_equal 1, ev_layout[:compile], "(d) the affected unit recompiles exactly"

    page = EntryRef.new(theme, "page")
    # warm the page entry once (independent of the edited card), then re-render
    p3.render_request(p3.il_adapter, page, ctx, fingerprint_key: "route:page")
    p4 = fleet.spawn_process
    _, ev_page = p4.render_request(p4.il_adapter, page, ctx, fingerprint_key: "route:page")
    assert_equal 0, ev_page[:compile], "(d) an entry NOT depending on the edit does not recompile"
    assert_operator ev_page[:store_hit], :>=, 1

    # post-edit parity still byte-identical
    il_edit, = p3.render_request(p3.il_adapter, layout, ctx)
    ctl_edit, = control_proc.render_request(control_proc.ruby_adapter, layout, ctx)
    assert_equal ctl_edit, il_edit, "(f) parity holds after a theme edit"

    # === (e) Cross-"shop" sharing — same-digest assets, one cache entry =======
    fleet2 = Fleet.new
    shop_a = build_theme(fleet2, "shop-A")
    shop_b = build_theme(fleet2, "shop-B") # identical bodies -> identical digests
    assert_equal composite_key(shop_a, "layout"), composite_key(shop_b, "layout"),
      "(e) two shops on identical assets map to the SAME cache key"

    pa = fleet2.spawn_process
    pa.render_request(pa.il_adapter, EntryRef.new(shop_a, "layout"), ctx, fingerprint_key: fp)

    pb = fleet2.spawn_process # a different process ("another shop's request")
    pb.store.reset_stats!
    fleet2.bodies.reset_fetches!
    _, ev_b = pb.render_request(pb.il_adapter, EntryRef.new(shop_b, "layout"), ctx, fingerprint_key: fp)
    assert_equal 0, ev_b[:compile], "(e) shop B reuses shop A's compiled artifact — no recompile"
    assert_equal 0, fleet2.bodies.fetch_count, "(e) shop B fetches no bodies — content-addressed reuse"
    assert_operator ev_b[:store_hit], :>=, 1
  end

  # ---------------------------------------------------------------------------
  # (f) The verifier gate on its own: many assign shapes, both engines diffed.
  # ---------------------------------------------------------------------------
  def test_verifier_diff_is_byte_identical_across_assign_shapes
    fleet = Fleet.new
    theme = build_theme(fleet, "verify-shop")
    layout = EntryRef.new(theme, "layout")
    proc = fleet.spawn_process

    shapes = [
      ASSIGNS,
      ASSIGNS.merge("products" => []),
      ASSIGNS.merge("title" => "", "products" => [{ "title" => "Solo", "price" => 0 }]),
      ASSIGNS.merge("products" => [{ "title" => "No price" }]), # missing key -> both blank
    ]

    shapes.each_with_index do |assigns, i|
      c_il = MockLiquidContext.new(assigns: deep_dup(assigns))
      c_rb = MockLiquidContext.new(assigns: deep_dup(assigns))
      il_out, = proc.render_request(proc.il_adapter, layout, c_il)
      rb_out, = proc.render_request(proc.ruby_adapter, layout, c_rb)
      assert_equal rb_out, il_out, "assign shape ##{i} must be byte-identical between engines"
    end
  end

  # ---------------------------------------------------------------------------
  # ScopeShim mirrors liquid-vm's ContextShim.
  # ---------------------------------------------------------------------------
  def test_scope_shim_bridges_context_and_engine_scope
    context = MockLiquidContext.new(assigns: { "host_only" => "H" })
    scope = LiquidIL::Scope.new({ "engine_var" => 42 })
    shim = ScopeShim.new(context, scope)

    # engine scope stashed at registers.static[:liquid_il_scope]
    assert_same scope, context.registers.static[ScopeShim::STASH_KEY]

    # scope reads/writes route to the engine scope
    assert_equal 42, shim["engine_var"]
    shim["written"] = 7
    assert_equal 7, scope.lookup("written")

    # unknown methods delegate to the wrapped Liquid::Context
    assert_equal({ "host_only" => "H" }, shim.assigns)
    assert_equal [context.assigns], shim.environments

    # handle_error stays on the host context and collects
    msg = shim.handle_error(LiquidIL::RuntimeError.new("boom"))
    assert_equal "Liquid error: boom", msg
    assert_equal 1, context.errors.size

    # isolated subcontext -> isolated engine scope, parent stash intact
    iso = shim.new_isolated_subcontext
    assert_instance_of ScopeShim, iso
    refute_same scope, iso.scope
    assert_same scope, context.registers.static[ScopeShim::STASH_KEY]
  end

  # ---------------------------------------------------------------------------
  # AdapterRouter.from_context precedence: forced -> beta flag -> default.
  # ---------------------------------------------------------------------------
  def test_adapter_router_precedence
    proc = Fleet.new.spawn_process
    router = proc.router

    default = router.from_context(ctx)
    assert_equal "liquid-ruby", default.slug, "default ships LiquidIL dark"
    assert_equal "enabled", default.cohort

    forced = router.from_context(ctx(self_verify: "liquid-il"))
    assert_equal "liquid-il", forced.slug, "self-verify header forces the engine"
    assert_equal "verifier", forced.cohort

    beta = router.from_context(ctx(shop: MockShop.new(id: 9, features: ["f_liquid_il_rendering"])))
    assert_equal "liquid-il", beta.slug, "beta flag opts a shop in"
    assert_equal "beta", beta.cohort

    # forced beats the flag
    both = router.from_context(
      ctx(shop: MockShop.new(id: 9, features: ["f_liquid_il_rendering"]), self_verify: "liquid-ruby"),
    )
    assert_equal "liquid-ruby", both.slug
    assert_equal "verifier", both.cohort
  end

  # ---------------------------------------------------------------------------
  # eval_infallible + the host-filter bridge seam.
  # ---------------------------------------------------------------------------
  def test_eval_infallible_and_filter_bridge
    proc = Fleet.new.spawn_process
    il = proc.il_adapter

    assert_equal "6", il.eval_infallible(MockLiquidContext.new(assigns: { "x" => 5 }), "x | plus: 1")
    # a genuine parse failure returns nil rather than raising (infallible)
    assert_nil il.eval_infallible(MockLiquidContext.new(assigns: {}), "foo bar baz")

    # Host filters registered globally are visible to LiquidIL (the strainer-
    # rebinding seam). Kept out of the parity templates so both engines agree.
    LiquidIL.register_filter(MockHostFilters)
    assert LiquidIL::Filters.global_registry.key?("shout")
    assert_equal "HI!!!", LiquidIL.render("{{ 'hi' | shout }}")
  end

  module MockHostFilters
    def shout(input)
      "#{input.to_s.upcase}!!!"
    end
  end

  private

  # Recompute the composite cache key the way the coder does — used only to
  # assert key equality/inequality in the tests.
  def composite_key(theme, entry_name)
    coder = LiquidIlCoder.new
    ref = EntryRef.new(theme, entry_name)
    fs = RecordingFileSystem.new(theme)
    LiquidIL::Context.new(file_system: fs).parse(theme.load_named(entry_name))
    ed = coder.entry_digest(ref)
    coder.composite_digest(ed, ref, fs.inlined_names)
  end

  def print_timings(timings)
    puts "\n  storefront_mock timings (µs):"
    timings.each { |label, us| puts format("    %-24s %8.1f", label, us) }
  end
end
