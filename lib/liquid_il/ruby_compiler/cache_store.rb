# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Small thread-safe process cache with clear-on-capacity eviction. Keys retain
    # their complete immutable values, so Ruby Hash collisions are resolved by
    # equality rather than by a separate digest layer.
    class BoundedCache
      attr_reader :limit

      def initialize(limit)
        @limit = limit
        @entries = {}
        @mutex = Mutex.new
      end

      def [](key)
        @mutex.synchronize { @entries[key] }
      end

      def store(key, value)
        @mutex.synchronize do
          @entries.clear if @entries.size >= @limit && !@entries.key?(key)
          @entries[key] = value
        end
        value
      end

      def clear
        @mutex.synchronize { @entries.clear }
      end

      def size
        @mutex.synchronize { @entries.size }
      end

      # Test support for exercising eviction without compiling +limit+ templates.
      def fill_for_test(value = nil)
        @mutex.synchronize do
          @entries.clear
          @limit.times { |index| @entries[index] = value }
        end
      end
    end

    # Collision-safe bucket cache for IL discovery. The fast structural hash
    # chooses a bucket; a retained complete snapshot proves equality.
    class BoundedBucketCache < BoundedCache
      def initialize(limit)
        super
        @entry_count = 0
      end

      def find(bucket_key, snapshot)
        @mutex.synchronize do
          entry = @entries[bucket_key]&.find { |candidate, _value| candidate == snapshot }
          entry&.last
        end
      end

      def store_entry(bucket_key, snapshot, value)
        @mutex.synchronize do
          bucket = @entries[bucket_key]
          existing = bucket&.find { |candidate, _stored| candidate == snapshot }
          return existing.last if existing

          if @entry_count >= @limit
            @entries.clear
            @entry_count = 0
            bucket = nil
          end
          (@entries[bucket_key] = (bucket || [])) << [snapshot, value]
          @entry_count += 1
        end
        value
      end

      def clear
        @mutex.synchronize do
          @entries.clear
          @entry_count = 0
        end
      end

      def size
        @mutex.synchronize { @entry_count }
      end
    end

    # Owns every process-wide compiler cache. Keeping lifecycle and bounds here
    # prevents emitters from growing ad-hoc class-variable registries.
    module CompilerCaches
      ISEQ = BoundedCache.new(1_000)
      PARTIAL = BoundedCache.new(500)
      INDENTED_PARTIAL_BODY = BoundedCache.new(500)
      BOUND_PARTIAL_BODY = BoundedCache.new(500)
      DEDUP_DISCOVERY = BoundedBucketCache.new(500)

      ALL = [ISEQ, PARTIAL, INDENTED_PARTIAL_BODY, BOUND_PARTIAL_BODY,
             DEDUP_DISCOVERY].freeze

      def self.clear
        ALL.each(&:clear)
      end
    end

    # Compiler-facing ISeq cache operations. The owner, bounds, synchronization,
    # and source-key retention all stay outside the orchestration class.
    module CompilationCache
      def self.included(compiler)
        compiler.extend(ClassMethods)
      end

      private

      def eval_ruby(source, partial_constants = nil)
        if (bin = CompilerCaches::ISEQ[source])
          RubyVM::InstructionSequence.load_from_binary(bin).eval
        else
          iseq = RubyVM::InstructionSequence.compile(RubyCompiler.compact_source(source), "(liquid_il_ruby)")
          CompilerCaches::ISEQ.store(source.dup.freeze, iseq.to_binary.freeze)
          iseq.eval
        end
      rescue SyntaxError
        nil
      end

      module ClassMethods
        def iseq_binary_for(ruby_source)
          cached = CompilerCaches::ISEQ[ruby_source]
          return cached if cached

          iseq = RubyVM::InstructionSequence.compile(compact_source(ruby_source), "(liquid_il_structured)")
          CompilerCaches::ISEQ.store(ruby_source.dup.freeze, iseq.to_binary.freeze)
        end
      end
    end
  end
end
