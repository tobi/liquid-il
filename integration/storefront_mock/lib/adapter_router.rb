# frozen_string_literal: true

module StorefrontMock
  # Mirrors LiquidAdapter.from_context precedence:
  #   1. forced   — per-request engine forcing (the replay / internal-header path)
  #   2. beta flag — shop.features.enabled?("f_liquid_il_rendering")
  #   3. default   — the reference control (LiquidIL ships DARK: reachable only
  #                  via the forced chain or the beta flag, never the default)
  #
  # The cohort set on the chosen adapter is the stats dimension the host tags renders
  # with ("verifier", "beta", "enabled").
  class AdapterRouter
    FORCE_SLUGS = %w[liquid-il liquid-ruby].freeze
    BETA_FLAG = "f_liquid_il_rendering"

    def initialize(il:, ruby:)
      @il = il
      @ruby = ruby
    end

    def from_context(context)
      forced = context.self_verify_features&.to_s&.strip
      if forced && FORCE_SLUGS.include?(forced)
        adapter = forced == "liquid-il" ? @il : @ruby
        return tag(adapter, "verifier")
      end

      if context.shop&.features&.enabled?(BETA_FLAG)
        return tag(@il, "beta")
      end

      tag(@ruby, "enabled")
    end

    private

    def tag(adapter, cohort)
      adapter.cohort = cohort
      adapter
    end
  end
end
