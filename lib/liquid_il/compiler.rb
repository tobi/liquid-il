# frozen_string_literal: true

module LiquidIL
  # Compiler - wraps parser and provides optimization passes
  class Compiler
    attr_reader :source

    def initialize(source, **options)
      @source = source
      @options = options
    end

    def compile
      parser = Parser.new(@source)
      instructions = parser.parse

      # Optional optimization passes
      optimize(instructions) if @options[:optimize]

      instructions
    end

    private

    def optimize(instructions)
      # Optimization pass 1: Merge consecutive WRITE_RAW
      merge_raw_writes(instructions)

      # Optimization pass 2: Remove unreachable code after unconditional jumps
      remove_unreachable(instructions)

      instructions
    end

    def merge_raw_writes(instructions)
      i = 0
      while i < instructions.length - 1
        if instructions[i][0] == IL::WRITE_RAW && instructions[i + 1][0] == IL::WRITE_RAW
          # Merge the two writes
          instructions[i] = [IL::WRITE_RAW, instructions[i][1] + instructions[i + 1][1]]
          instructions.delete_at(i + 1)
        else
          i += 1
        end
      end
    end

    def remove_unreachable(instructions)
      # Remove instructions after unconditional jumps until we hit a label
      i = 0
      while i < instructions.length - 1
        if instructions[i][0] == IL::JUMP || instructions[i][0] == IL::HALT
          # Check if next instruction is a label
          j = i + 1
          while j < instructions.length && instructions[j][0] != IL::LABEL
            instructions.delete_at(j)
          end
        end
        i += 1
      end
    end
  end
end
