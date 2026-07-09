# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Bounded process-wide interning for generated local names and loop-number
    # ranges. Values are never reused, even after key eviction, so cached source
    # fragments cannot alias a newly interned symbol. A compilation retains the
    # returned symbol in its own metadata/maps; the bounded table is only a
    # deduplication aid for later compilations.
    class SymbolTable
      attr_reader :limit

      def initialize(limit, &formatter)
        @limit = limit
        @formatter = formatter
        @entries = {}
        @next_id = 0
        @mutex = Mutex.new
      end

      def intern(key)
        @mutex.synchronize do
          return @entries[key] if @entries.key?(key)

          @entries.clear if @entries.size >= @limit
          id = @next_id
          @next_id += 1
          @entries[key] = @formatter.call(id)
        end
      end

      # Evicts keys but deliberately preserves the monotonic id. Cached bodies
      # may still contain any previously returned symbol.
      def clear
        @mutex.synchronize { @entries.clear }
      end

      def size
        @mutex.synchronize { @entries.size }
      end
    end

    module CodegenSymbols
      FROZEN_ARRAYS = SymbolTable.new(4_096) { |id| "_fa#{id}__".freeze }
      PARTIAL_LOOP_BASES = SymbolTable.new(4_096) { |id| (id + 1) * 100 }

      ALL = [FROZEN_ARRAYS, PARTIAL_LOOP_BASES].freeze

      def self.clear
        ALL.each(&:clear)
      end
    end
  end
end
