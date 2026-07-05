# frozen_string_literal: true

module StorefrontMock
  # Static + instance registers, like Liquid::Context#registers (a Registers
  # object exposing #static). Engine state is stashed in `static`, exactly like
  # liquid-vm parks its state at `registers.static[:liquid_vm_state]`.
  class MockRegisters
    def initialize(static: {}, instance: {})
      @static = static
      @instance = instance
    end

    attr_reader :static

    def [](key)
      @instance.key?(key) ? @instance[key] : @static[key]
    end

    def []=(key, value)
      @instance[key] = value
    end

    def key?(key)
      @instance.key?(key) || @static.key?(key)
    end
  end

  class MockFeatures
    def initialize(enabled = [])
      @enabled = enabled.map(&:to_s)
    end

    # The codebase's enforced idiom: shop.features.enabled?("f_...").
    def enabled?(flag)
      @enabled.include?(flag.to_s)
    end
  end

  class MockShop
    attr_reader :id, :features

    def initialize(id:, features: [])
      @id = id
      @features = MockFeatures.new(features)
    end
  end

  # Minimal Liquid::Context stand-in — only the surface the adapter and shim
  # actually touch. Assigns, registers, the error surface, and environments
  # stay here (host-side); the engine's scope/variable storage lives elsewhere
  # and is bridged in by ScopeShim.
  class MockLiquidContext
    attr_reader :assigns, :registers, :environments, :errors, :resource_limits, :shop
    attr_accessor :self_verify_features, :error_mode

    def initialize(assigns: {}, shop: nil, static_registers: {},
                   resource_limits: nil, error_mode: :lax,
                   self_verify_features: nil)
      @assigns = stringify(assigns)
      @environments = [@assigns]
      @registers = MockRegisters.new(static: static_registers)
      @errors = []
      @resource_limits = resource_limits
      @error_mode = error_mode
      @shop = shop
      @self_verify_features = self_verify_features
    end

    def [](key)
      find_variable(key)
    end

    def []=(key, value)
      @assigns[key.to_s] = value
    end

    def find_variable(key)
      k = key.to_s
      @environments.each { |env| return env[k] if env.key?(k) }
      nil
    end

    # Collect errors like Liquid::Context#handle_error: append and return the
    # formatted inline string. A strict host would re-raise; the mock stays lax.
    # LiquidIL error text already matches reference per liquid-spec, so routing
    # errors here keeps the storefront's single error-rendering path.
    def handle_error(error, _line_number = nil)
      @errors << error
      message = error.respond_to?(:message) ? error.message : error.to_s
      "Liquid error: #{LiquidIL.clean_error_message(message)}"
    end

    private

    def stringify(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end
end
