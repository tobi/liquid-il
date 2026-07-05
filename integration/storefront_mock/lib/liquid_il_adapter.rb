# frozen_string_literal: true

module StorefrontMock
  # LiquidIL as a storefront engine. parse() compiles-or-loads through the
  # CompiledTemplateCache (live-proc tier -> preloaded -> memoized -> tiered KV
  # -> compile) and returns a RenderableTemplate over the loaded CompiledArtifact.
  class LiquidIlAdapter
    include AdapterInterface

    SLUG = "liquid-il"

    def initialize(cache)
      @cache = cache
      @cohort = "enabled"
    end

    def slug = SLUG

    def parse(entry_ref, parse_options = {})
      artifact = @cache.fetch(entry_ref, parse_options)
      IlRenderableTemplate.new(self, artifact)
    end

    # Build the engine Scope from the host context and wrap it in the shim.
    # This is the exact scope shape CompiledArtifact#render builds internally,
    # so render_scope output is byte-identical to a plain .render(assigns).
    #
    # The external-partial PartialProvider rides in on registers["partial_provider"]
    # (parked there by AppProcess#render_request) exactly like SFR passes
    # cross-cutting request state; Scope#initialize picks it up so external
    # `{% render/include %}` sites resolve their per-file artifacts at render time.
    def wrap_context(context)
      registers = {}
      if context.registers && (provider = context.registers["partial_provider"])
        registers["partial_provider"] = provider
      end
      scope = LiquidIL::Scope.new(context.assigns, registers: registers)
      scope.render_errors = true
      scope.resource_limits = context.resource_limits if context.resource_limits
      global = LiquidIL::Filters.global_registry
      scope.custom_filters = global unless global.empty?
      ScopeShim.new(context, scope)
    end

    # Evaluate a Liquid expression against the context, never raising.
    def eval_infallible(context, expression)
      LiquidIL.render("{{ #{expression} }}", context.assigns)
    rescue StandardError
      nil
    end
  end

  # The RenderableTemplate wrapper the adapter contract requires. Rendering runs
  # the loaded artifact's proc against the shim-owned engine scope.
  class IlRenderableTemplate
    def initialize(adapter, artifact)
      @adapter = adapter
      @artifact = artifact
    end

    attr_reader :artifact

    def render(context)
      shim = @adapter.wrap_context(context)
      @artifact.render_scope(shim.scope)
    end

    def render!(context)
      shim = @adapter.wrap_context(context)
      shim.scope.render_errors = false
      @artifact.render_scope(shim.scope)
    end

    # Native buffered render: CompiledArtifact#render_to_output_buffer appends
    # directly into the caller's preallocated buffer (the storefront renderer's
    # 16KB-per-request buffer) instead of allocating a fresh String and copying.
    # The external-partial provider rides in on registers["partial_provider"],
    # so external `{% render %}` sites resolve at render time here too.
    def render_to_output_buffer(context, output)
      provider = context.registers && context.registers["partial_provider"]
      @artifact.render_to_output_buffer(context.assigns, output, partial_provider: provider)
    end
  end
end
