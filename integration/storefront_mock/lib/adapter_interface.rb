# frozen_string_literal: true

module StorefrontMock
  # The scouted adapter contract (app/liquid/liquid_adapter/interface.rb),
  # trimmed to the surface this mock exercises:
  #
  #   parse(template_obj, parse_options) -> a RenderableTemplate that responds
  #     to render(context), render!(context), render_to_output_buffer(context, output)
  #   wrap_context(context)   -> a per-render context bridge
  #   eval_infallible(context, expression) -> value or nil, never raises
  #   slug                    -> engine identifier ("liquid-il" / "liquid-ruby")
  #   cohort                  -> stats dimension set by the router
  #
  # `parse_raw` in SFR may return ANY object responding to render/render!/
  # render_to_output_buffer; nothing else is assumed.
  module AdapterInterface
    def slug
      raise NotImplementedError, "#{self.class}#slug"
    end

    def parse(_template_obj, _parse_options = {})
      raise NotImplementedError, "#{self.class}#parse"
    end

    def wrap_context(_context)
      raise NotImplementedError, "#{self.class}#wrap_context"
    end

    def eval_infallible(_context, _expression)
      raise NotImplementedError, "#{self.class}#eval_infallible"
    end

    def cohort
      @cohort ||= "enabled"
    end

    attr_writer :cohort
  end
end
