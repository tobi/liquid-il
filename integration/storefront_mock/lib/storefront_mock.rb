# frozen_string_literal: true

# A faithful miniature of the Shopify storefront renderer's integration
# substrate, entirely mocked in-repo, proving the LiquidIL engine-adapter +
# CompiledTemplateCache + live-proc design end to end. See README.md.

require "liquid_il"
require "liquid"

require_relative "mock_theme"
require_relative "mock_key_value_store"
require_relative "mock_liquid_context"
require_relative "scope_shim"
require_relative "adapter_interface"
require_relative "compiled_template_cache"
require_relative "liquid_il_adapter"
require_relative "liquid_ruby_adapter"
require_relative "adapter_router"

module StorefrontMock
  # The fleet-wide cache fabric: the REMOTE memcached cluster plus the shared,
  # shop-agnostic body store. Both are shared across every process. Each process
  # spun below gets its OWN node-local daemon and its own live-proc tier —
  # exactly the production shape (node-local is per host, remote is shared).
  class Fleet
    attr_reader :remote, :bodies

    def initialize
      @bodies = BodyStore.new
      @remote = MockKeyValueStore.new("remote")
    end

    def new_theme(id)
      MockTheme.new(id, @bodies)
    end

    # Spawn a fresh "process": a cold node-local tier over the shared remote,
    # new request layers, and a new (empty) live-proc tier.
    def spawn_process(live_bytes: 16 * 1024 * 1024)
      store = TieredStore.new(MockKeyValueStore.new("node_local"), @remote)
      AppProcess.new(store, live_bytes: live_bytes)
    end
  end

  # One renderer process. Holds the per-engine CompiledTemplateCache instances
  # (the LiquidIL one carries the process-global live-proc tier), the process's
  # node-local-fronted store, and a router.
  class AppProcess
    attr_reader :store, :il_cache, :ruby_cache, :il_adapter, :ruby_adapter, :router

    def initialize(store, live_bytes: 16 * 1024 * 1024)
      @store = store
      @il_cache = CompiledTemplateCache.new(
        coder: LiquidIlCoder.new,
        store: store,
        live: LiquidIL::TemplateCache.new(max_bytes: live_bytes),
      )
      @ruby_cache = CompiledTemplateCache.new(coder: LiquidRubyCoder.new, store: store)
      @il_adapter = LiquidIlAdapter.new(@il_cache)
      @ruby_adapter = LiquidRubyAdapter.new(@ruby_cache)
      @router = AdapterRouter.new(il: @il_adapter, ruby: @ruby_adapter)
    end

    def cache_for(adapter)
      adapter.equal?(@il_adapter) ? @il_cache : @ruby_cache
    end

    # Drive one request through a chosen adapter: open the request layers, park
    # the external-partial PartialProvider on the context registers, parse
    # (compile-or-load), render, close the request (save fingerprint). Returns
    # [output, events]. The provider resolves external partials lazily through
    # the same cache tiers, so the keys it touches join the request fingerprint.
    def render_request(adapter, entry_ref, context, fingerprint_key: nil, parse_options: {})
      cache = cache_for(adapter)
      cache.begin_request(fingerprint_key)
      if (provider = cache.partial_provider(entry_ref, parse_options))
        context.registers["partial_provider"] = provider
      end
      renderable = adapter.parse(entry_ref, parse_options)
      output = renderable.render(context)
      events = cache.end_request
      [output, events]
    end
  end
end
