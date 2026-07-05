# frozen_string_literal: true

require "liquid"

module StorefrontMock
  # The control engine, over the reference `liquid` gem. Same interface, no
  # compiled caching (parse each time) — the honest performance and conformance
  # baseline. Its render output is the oracle the verifier diff compares against.
  class LiquidRubyAdapter
    include AdapterInterface

    SLUG = "liquid-ruby"

    def initialize(cache)
      @cache = cache
      @cohort = "enabled"
    end

    def slug = SLUG

    def parse(entry_ref, parse_options = {})
      template = @cache.fetch(entry_ref, parse_options)
      RubyRenderableTemplate.new(self, template)
    end

    # The reference engine drives its own Liquid::Context off the assigns hash;
    # there is no engine scope to bridge, so the host context is used directly.
    def wrap_context(context)
      context
    end

    def eval_infallible(context, expression)
      Liquid::Template.parse("{{ #{expression} }}").render(stringify(context.assigns))
    rescue StandardError
      nil
    end

    private

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end

  class RubyRenderableTemplate
    def initialize(adapter, template)
      @adapter = adapter
      @template = template
    end

    def render(context)
      @template.render(assigns_for(context))
    end

    def render!(context)
      @template.render!(assigns_for(context))
    end

    def render_to_output_buffer(context, output)
      output << render(context)
      output
    end

    private

    def assigns_for(context)
      context.assigns.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end
end
