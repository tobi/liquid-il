# frozen_string_literal: true

module StorefrontMock
  # Mirror of the host engine's context-shim pattern.
  #
  # Wraps a MockLiquidContext. Unknown methods delegate to it, so assigns,
  # registers, environments, and the error surface all stay host-side. Scope
  # reads/writes, isolation, and resource accounting route to a LiquidIL::Scope
  # stashed at `registers.static[:liquid_il_scope]` — the same convention
  # liquid-vm uses for `registers.static[:liquid_vm_state]`.
  #
  # `handle_error` deliberately stays on the wrapped Ruby context: the host renders
  # error text through Liquid::Context#handle_error, and LiquidIL's text already
  # matches reference, so errors flow there rather than being emitted inline.
  class ScopeShim
    STASH_KEY = :liquid_il_scope

    def initialize(context, scope, stash: true)
      @context = context
      @scope = scope
      @context.registers.static[STASH_KEY] = scope if stash
    end

    attr_reader :context, :scope

    # --- scope reads/writes route to the engine scope ---
    def [](key)
      @scope.lookup(key.to_s)
    end

    def []=(key, value)
      @scope.assign(key.to_s, value)
    end

    def find_variable(key)
      @scope.lookup(key.to_s)
    end

    def registers
      @context.registers
    end

    # --- error surface stays on the host Ruby context ---
    def handle_error(error, line_number = nil)
      @context.handle_error(error, line_number)
    end

    # --- isolated subcontext -> isolated engine scope (our Scope#isolated) ---
    # A fresh sub-shim per partial, over an isolated scope. It does NOT clobber
    # the parent's stash (stash: false), matching the host shim's isolated-subcontext behavior.
    def new_isolated_subcontext
      ScopeShim.new(@context, @scope.isolated, stash: false)
    end

    # Everything else delegates to the wrapped Liquid::Context.
    def respond_to_missing?(name, include_private = false)
      @context.respond_to?(name, include_private) || super
    end

    def method_missing(name, *args, **kwargs, &blk)
      if @context.respond_to?(name)
        @context.public_send(name, *args, **kwargs, &blk)
      else
        super
      end
    end
  end
end
