# frozen_string_literal: true

module LiquidIL
  # Registry for compile-time and host-rendered custom tags.
  #
  # Tags are registered with a name, end tag, and a mode:
  #   :passthrough — parse and evaluate body normally (like {% style %})
  #   :discard     — skip body entirely, emit nothing (like {% schema %})
  #   :raw         — capture body as raw text, no Liquid evaluation (like {% raw %})
  #   :block       — custom block with setup/teardown procs for codegen
  #
  # Usage:
  #   LiquidIL::Tags.register("style", end_tag: "endstyle", mode: :passthrough)
  #   LiquidIL::Tags.register("schema", end_tag: "endschema", mode: :discard)
  #   LiquidIL::Tags.register("paginate", end_tag: "endpaginate", mode: :block,
  #     setup: ->(args, builder) { ... },    # emit IL before body
  #     teardown: ->(args, builder) { ... }) # emit IL after body
  #
  module Tags
    TagDef = Struct.new(:name, :end_tag, :mode, :setup, :teardown, keyword_init: true)
    HostTagDef = Struct.new(
      :name,
      :end_tag,
      :selector,
      :cache_key,
      :compiler,
      :compiler_cache_key,
      :reads_scope,
      :writes_scope,
      :can_interrupt,
      keyword_init: true,
    ) do
      def selected?(markup, error_mode: nil)
        case selector
        when :always
          true
        when :non_literal, :non_literal_first_argument
          !Tags.literal_first_argument?(markup)
        else
          selector.arity == 1 ? selector.call(markup) : selector.call(markup, error_mode)
        end
      end

      def selector_fingerprint
        selector.is_a?(Symbol) ? selector.to_s : cache_key
      end

      def compiler_fingerprint
        compiler && compiler_cache_key
      end

      # Compact effect metadata carried by HOST_TAG IL. Defaults are supplied
      # by register_host and remain fully conservative; hosts must explicitly
      # opt into narrower semantics before codegen can retain optimizations.
      def effect_bits
        bits = 0
        bits |= IL::HOST_TAG_READS_SCOPE unless reads_scope == false
        bits |= IL::HOST_TAG_WRITES_SCOPE unless writes_scope == false
        bits |= IL::HOST_TAG_CAN_INTERRUPT unless can_interrupt == false
        bits
      end

      def compile(**metadata)
        compiler ? compiler.call(**metadata) : metadata.fetch(:source)
      end
    end

    @registry = {}
    @host_registry = {}
    @version = 0

    class << self
      attr_reader :version

      def register(name, end_tag: nil, mode: :passthrough, setup: nil, teardown: nil)
        name = name.to_s.freeze
        end_tag = end_tag.to_s.freeze if end_tag
        @registry[name] = TagDef.new(
          name: name,
          end_tag: end_tag,
          mode: mode,
          setup: setup,
          teardown: teardown,
        )
        rebuild_end_tags!
        @version += 1
      end

      # Register a tag whose parse/render implementation belongs to the host.
      # Host block bodies are opaque and are never parsed or retained by
      # LiquidIL. At render time Scope#render_host_tag (or host_tag_renderer) is
      # called with a deterministic source-local slot and source identity.
      #
      # Selection happens at compile time and must depend only on +markup+.
      # Named selectors are intrinsically cache-safe. A custom callable must
      # provide a stable cache_key that changes whenever its semantics change.
      # This lets a host intercept only non-literal render/include forms while
      # leaving literal partials on LiquidIL's native compile-time path:
      #
      #   Tags.register_host("render", select: :non_literal)
      #   Tags.register_host("include", select: :non_literal)
      #   Tags.register_host("form", end_tag: "endform")
      #
      # Host effects default to fully opaque. A host may explicitly narrow
      # them when its implementation is known not to observe or mutate Liquid
      # scope and/or not to propagate break/continue:
      #
      #   Tags.register_host("asset", reads_scope: false,
      #     writes_scope: false, can_interrupt: false)
      #
      def register_host(name, end_tag: nil, select: :always, cache_key: nil,
                        compiler: nil, compiler_cache_key: nil, reads_scope: true,
                        writes_scope: true, can_interrupt: true, &predicate)
        if predicate
          unless select == :always
            raise ArgumentError, "pass either select: or a predicate block, not both"
          end
          select = predicate
        end

        if select.respond_to?(:call)
          if cache_key.nil? || cache_key.to_s.empty?
            raise ArgumentError, "host tag predicates require a stable cache_key"
          end
        elsif !%i[always non_literal non_literal_first_argument].include?(select)
          raise ArgumentError, "unknown host tag selector #{select.inspect}"
        end

        if compiler && (compiler_cache_key.nil? || compiler_cache_key.to_s.empty?)
          raise ArgumentError, "host tag compilers require a stable compiler_cache_key"
        end

        {
          reads_scope: reads_scope,
          writes_scope: writes_scope,
          can_interrupt: can_interrupt,
        }.each do |effect, value|
          unless value == true || value == false
            raise ArgumentError, "#{effect} must be true or false"
          end
        end

        name = name.to_s.freeze
        end_tag = end_tag.to_s.freeze if end_tag
        @host_registry[name] = HostTagDef.new(
          name: name,
          end_tag: end_tag,
          selector: select,
          cache_key: cache_key&.to_s&.freeze,
          compiler: compiler,
          compiler_cache_key: compiler_cache_key&.to_s&.freeze,
          reads_scope: reads_scope,
          writes_scope: writes_scope,
          can_interrupt: can_interrupt,
        ).freeze
        rebuild_end_tags!
        @version += 1
      end

      def registered?(name)
        key = name.to_s
        @registry.key?(key) || @host_registry.key?(key)
      end

      # Compile-time/static definitions. Kept as #[] for API compatibility.
      def [](name)
        @registry[name.to_s]
      end

      def static_registered?(name)
        @registry.key?(name.to_s)
      end

      def host_registered?(name)
        @host_registry.key?(name.to_s)
      end

      def host_definition(name)
        @host_registry[name.to_s]
      end

      def host_for(name, markup, error_mode: nil)
        definition = host_definition(name)
        definition if definition&.selected?(markup.to_s, error_mode:)
      end

      def host?(name, markup = "")
        !host_for(name, markup).nil?
      end

      # Source-only predicate shared by render/include host policies. A quoted
      # first argument remains on the native static-partial path; everything
      # else is delegated to the host.
      def literal_first_argument?(markup)
        bytes = markup.to_s
        index = 0
        while (byte = bytes.getbyte(index)) && (byte == 32 || byte == 9 || byte == 10 || byte == 13)
          index += 1
        end
        if bytes.getbyte(index) == 58 # Storefront's lax `{% render: 'name' %}` syntax.
          index += 1
          while (byte = bytes.getbyte(index)) && (byte == 32 || byte == 9 || byte == 10 || byte == 13)
            index += 1
          end
        end
        quote = bytes.getbyte(index)
        quote == 34 || quote == 39
      end

      def end_tag?(name)
        @end_tags&.include?(name.to_s)
      end

      def block_start?(name)
        key = name.to_s
        !!(@registry[key]&.end_tag || @host_registry[key]&.end_tag)
      end

      # Registered block start tag names (for nesting tracking)
      def start_tags
        (@registry.each_value.to_a + @host_registry.each_value.to_a)
          .filter_map { |tag_def| tag_def.name if tag_def.end_tag }
      end

      # All registered end tag names
      def end_tags
        @end_tags&.to_a || []
      end

      def clear!
        @registry.clear
        @host_registry.clear
        rebuild_end_tags!
        @version += 1
      end

      # Stable, JSON-safe description used by artifact/cache keys. Proc identity
      # is deliberately excluded; callers provide cache_key for that purpose.
      def compilation_cache_fingerprint
        static_defs = @registry.sort_by { |name, _| name }.map do |name, definition|
          [name, definition.end_tag, definition.mode.to_s]
        end
        host_defs = @host_registry.sort_by { |name, _| name }.map do |name, definition|
          [
            name,
            definition.end_tag,
            definition.selector_fingerprint,
            definition.compiler_fingerprint,
            definition.reads_scope,
            definition.writes_scope,
            definition.can_interrupt,
          ]
        end
        [@version, static_defs, host_defs].freeze
      end

      private

      def rebuild_end_tags!
        @end_tags = Set.new
        @registry.each_value { |definition| @end_tags.add(definition.end_tag) if definition.end_tag }
        @host_registry.each_value { |definition| @end_tags.add(definition.end_tag) if definition.end_tag }
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
