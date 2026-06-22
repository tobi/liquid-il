# frozen_string_literal: true

require "set"

module LiquidIL
  # StrainerTemplate is the computed class for the filters system.
  # Filter modules are mixed into the strainer class, which is then
  # instantiated for each render. This means filter methods can call
  # other methods in the same module (or other included modules) via self.
  class StrainerTemplate
    def initialize(context)
      @context = context
    end

    class << self
      def add_filter(filter)
        return if include?(filter)
        include(filter)
        filter_methods.merge(filter.public_instance_methods.map(&:to_s))
      end

      def invokable?(method)
        filter_methods.include?(method.to_s)
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@filter_methods, @filter_methods.dup)
      end

      private

      def filter_methods
        @filter_methods ||= Set.new
      end
    end

    def invoke(method, *args)
      if self.class.invokable?(method)
        send(method, *args)
      else
        args.first
      end
    end
  end
end
