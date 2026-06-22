# frozen_string_literal: true

module LiquidIL
  # Registry for custom block tags.
  #
  # Tags are registered with a name, end tag, and a mode:
  #   :passthrough — parse and evaluate body normally (like {% style %})
  #   :discard     — skip body entirely, emit nothing (like {% schema %})
  #   :raw         — capture body as raw text, no Liquid evaluation (like {% raw %})
  #   :custom      — custom tag with handler class (before_block/after_block or render)
  #   :block       — custom block with setup/teardown procs for codegen
  #
  # Usage:
  #   LiquidIL::Tags.register("style", end_tag: "endstyle", mode: :passthrough)
  #   LiquidIL::Tags.register("schema", end_tag: "endschema", mode: :discard,
  #     on_parse: ->(raw_body, parse_context) { ... })
  #   LiquidIL::Tags.register("form", end_tag: "endform", mode: :custom,
  #     handler: FormHandler,
  #     parse_args: ->(markup) { [markup.strip] })
  #
  module Tags
    TagDef = Struct.new(
      :name, :end_tag, :mode, :setup, :teardown,
      :on_parse,     # proc(raw_body, parse_context) — called at parse time for :discard tags
      :handler,      # module/class with before_block/after_block or render — for :custom tags
      :parse_args,   # proc(markup) → array of expression strings/procs — for :custom tags
      keyword_init: true
    )

    @registry = {}
    @dynamic_render_handler = nil

    class << self
      # Global handler for {% render variable %} (dynamic render).
      # Must respond to `render(scope, output, name)`.
      attr_reader :dynamic_render_handler

      def register_dynamic_render_handler(handler)
        @dynamic_render_handler = handler
      end

      def register(name, end_tag: nil, mode: :passthrough, setup: nil, teardown: nil,
                   on_parse: nil, handler: nil, parse_args: nil)
        name = name.to_s.freeze
        end_tag = end_tag&.to_s&.freeze
        @registry[name] = TagDef.new(
          name: name,
          end_tag: end_tag,
          mode: mode,
          setup: setup,
          teardown: teardown,
          on_parse: on_parse,
          handler: handler,
          parse_args: parse_args,
        )
        # Also register end tag name so the nesting tracker knows about it
        if end_tag
          @end_tags ||= Set.new
          @end_tags.add(end_tag)
        end
      end

      def registered?(name)
        @registry.key?(name.to_s)
      end

      def [](name)
        @registry[name.to_s]
      end

      def end_tag?(name)
        @end_tags&.include?(name.to_s)
      end

      # All registered start tag names (for nesting tracking)
      def start_tags
        @registry.keys
      end

      # All registered end tag names
      def end_tags
        @end_tags&.to_a || []
      end

      def clear!
        @registry.clear
        @end_tags&.clear
        @dynamic_render_handler = nil
      end
    end

    # Built-in Shopify tags — registered on load, available to all adapters
    register "style",    end_tag: "endstyle",    mode: :passthrough
    register "schema",   end_tag: "endschema",   mode: :discard
    register "form",     end_tag: "endform",     mode: :passthrough
    register "paginate", end_tag: "endpaginate", mode: :passthrough,
      setup: ->(tag_args, builder) {
        # {% paginate collection by N %}
        # Emit IL: assign 'paginate' = runtime-computed paginate object
        if tag_args =~ /\A\s*(\S+(?:\.\S+)*)\s+by\s+(\d+)\s*\z/
          coll_path = $1
          page_size = $2.to_i
          # Push the collection path and page size as constants, then call a special
          # helper that will be handled by the ruby compiler
          builder.emit(:PAGINATE_SETUP, coll_path, page_size)
        end
      },
      teardown: ->(tag_args, builder) {
        builder.emit(:PAGINATE_TEARDOWN) if tag_args =~ /by\s+\d+/
      }
  end
end
