# frozen_string_literal: true

require_relative "liquid_il/lexer"
require_relative "liquid_il/parser"
require_relative "liquid_il/il"
require_relative "liquid_il/compiler"
require_relative "liquid_il/vm"
require_relative "liquid_il/context"
require_relative "liquid_il/drops"
require_relative "liquid_il/filters"

module LiquidIL
  class Error < StandardError; end
  class SyntaxError < Error; end
  class RuntimeError < Error; end

  class Template
    attr_reader :source, :instructions

    def initialize(source, instructions)
      @source = source
      @instructions = instructions
    end

    def render(assigns = {}, registers: {}, strict_errors: false, error_mode: :lax)
      context = Context.new(assigns, registers: registers, strict_errors: strict_errors)
      VM.execute(@instructions, context)
    end

    class << self
      def parse(source, **options)
        compiler = Compiler.new(source, **options)
        instructions = compiler.compile
        new(source, instructions)
      end
    end
  end
end
