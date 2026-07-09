# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # A Ruby expression plus semantic facts known at codegen time. Emitters use
    # these facts instead of reparsing generated Ruby with regexes to decide
    # output conversion, filter chaining, and required state.
    class CodeFragment
      attr_reader :source, :value_type, :output_policy, :cache_filter,
                  :cache_input, :may_error, :filter_dispatch_inner, :origin

      def initialize(source, value_type: :unknown, output_policy: nil,
                     cache_filter: nil, cache_input: nil, may_error: false,
                     filter_dispatch_inner: nil, origin: nil)
        @source = source.to_s
        @value_type = value_type
        @output_policy = output_policy || default_output_policy(value_type)
        @cache_filter = cache_filter
        @cache_input = cache_input
        @may_error = may_error
        @filter_dispatch_inner = filter_dispatch_inner
        @origin = origin
      end

      def self.wrap(value, **metadata)
        return value if value.is_a?(self) && metadata.empty?
        source = value.is_a?(self) ? value.source : value.to_s
        new(source, **metadata)
      end

      def to_s = @source
      def to_str = @source

      # Transitional compatibility for expression-building code. Semantic
      # decisions must read the fields above; string operations here are only
      # for Ruby source composition and will disappear as emitters are split.
      def method_missing(name, *args, &block)
        return @source.public_send(name, *args, &block) if @source.respond_to?(name)
        super
      end

      def respond_to_missing?(name, include_private = false)
        @source.respond_to?(name, include_private) || super
      end

      private

      def default_output_policy(value_type)
        case value_type
        when :string then :direct
        when :numeric then :to_s
        else :liquid
        end
      end
    end

    class FragmentStack < Array
      def <<(value)
        super(CodeFragment.wrap(value))
      end

      def push_fragment(source, **metadata)
        self << CodeFragment.new(source, **metadata)
      end
    end
  end
end
