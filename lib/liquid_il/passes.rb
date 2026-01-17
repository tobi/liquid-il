# frozen_string_literal: true

module LiquidIL
  # Optimization pass configuration
  #
  # Controls which optimization passes are enabled via the LIQUID_PASSES env var.
  # This is parsed at boot time for zero runtime overhead.
  #
  # ## Environment Variable Format
  #
  # LIQUID_PASSES accepts these formats:
  #   - (not set) - Enable all passes (default for production)
  #   - "*"       - Enable all passes
  #   - ""        - Disable all passes (baseline for testing)
  #   - "0,1,2"   - Enable only passes 0, 1, and 2
  #   - "*,-2"    - Enable all passes except pass 2
  #   - "*,-2,-3" - Enable all passes except passes 2 and 3
  #   - "1,2,-1"  - Enable pass 2 only (1 added then removed)
  #
  # ## Available Passes
  #
  #   0: inline_simple_partials     - Inline render/include with literal names
  #   1: fold_const_ops             - Fold constant IS_TRUTHY, BOOL_NOT, COMPARE
  #   2: fold_const_filters         - Fold constant filter calls (upcase, plus, etc.)
  #   3: fold_const_writes          - Fold CONST + WRITE_VALUE -> WRITE_RAW
  #   4: collapse_const_paths       - Merge chained LOOKUP_CONST_KEY
  #   5: collapse_find_var_paths    - Merge FIND_VAR + LOOKUP_CONST_PATH
  #   6: remove_redundant_is_truthy - Remove IS_TRUTHY after boolean ops
  #   7: remove_noops               - Remove NOOP instructions
  #   8: remove_jump_to_next_label  - Remove jumps to immediate next label
  #   9: merge_raw_writes           - Combine adjacent WRITE_RAW
  #  10: remove_unreachable         - Remove code after JUMP/HALT
  #  11: merge_raw_writes (again)   - Re-merge after removals
  #  12: fold_const_captures        - Fold constant capture blocks
  #  13: remove_empty_raw_writes    - Remove WRITE_RAW ""
  #  14: propagate_constants        - Replace FIND_VAR with known constants
  #  15: fold_const_filters (again) - Re-fold after propagation
  #  16: hoist_loop_invariants      - Move invariant lookups outside loops
  #  17: cache_repeated_lookups     - Cache repeated variable lookups
  #  18: value_numbering            - Eliminate redundant computations
  #  19: register_allocation        - Reuse dead temp register slots
  #  20: fuse_write_var             - Fuse FIND_VAR + WRITE_VALUE → WRITE_VAR
  #  21: strip_labels               - Remove LABEL instructions after linking
  #  22: remove_interrupt_checks    - Remove JUMP_IF_INTERRUPT/POP_INTERRUPT when unused
  #
  # ## Testing with Rake
  #
  #   rake passes                   # List all optimization passes
  #   rake test_pass[2]             # Run unit tests with only pass 2
  #   rake test_pass["*,-2"]        # Run unit tests with all except pass 2
  #   rake spec_pass[2]             # Run liquid-spec with only pass 2
  #   rake spec_each_pass           # Run spec with each pass individually
  #
  # ## Testing with liquidil CLI
  #
  #   bin/liquidil passes                              # List all passes
  #   bin/liquidil parse "{{ 'hi' | upcase }}" -p 2    # Parse with only pass 2
  #   bin/liquidil parse "{{ 'hi' | upcase }}" -p ""   # Parse with no passes
  #   bin/liquidil parse "{{ 'hi' | upcase }}" -p "*,-2" # All except pass 2
  #
  # ## Testing with Environment Variable
  #
  #   # Test only pass 2 (constant filter folding)
  #   LIQUID_PASSES=2 ruby -Ilib test/optimization_passes_test.rb
  #
  #   # Test all passes except register allocation
  #   LIQUID_PASSES="*,-19" ruby -Ilib test/optimization_passes_test.rb
  #
  #   # Test with no optimizations (baseline)
  #   LIQUID_PASSES="" ruby -Ilib test/optimization_passes_test.rb
  #
  module Passes
    # Names for each pass (for debugging/logging)
    # Add new passes here - ALL_PASSES is derived from this
    PASS_NAMES = {
      0 => "inline_simple_partials",
      1 => "fold_const_ops",
      2 => "fold_const_filters",
      3 => "fold_const_writes",
      4 => "collapse_const_paths",
      5 => "collapse_find_var_paths",
      6 => "remove_redundant_is_truthy",
      7 => "remove_noops",
      8 => "remove_jump_to_next_label",
      9 => "merge_raw_writes",
      10 => "remove_unreachable",
      11 => "merge_raw_writes_2",
      12 => "fold_const_captures",
      13 => "remove_empty_raw_writes",
      14 => "propagate_constants",
      15 => "fold_const_filters_2",
      16 => "hoist_loop_invariants",
      17 => "cache_repeated_lookups",
      18 => "value_numbering",
      19 => "register_allocation",
      20 => "fuse_write_var",
      21 => "strip_labels",
      22 => "remove_interrupt_checks"
    }.freeze

    # All available pass numbers (derived from PASS_NAMES)
    ALL_PASSES = PASS_NAMES.keys.sort.freeze

    class << self
      # Parse a pass specification string into a Set of enabled pass numbers
      #
      # @param spec [String, nil] Pass specification (e.g., "*", "0,1,2", "*,-2")
      # @return [Set<Integer>] Set of enabled pass numbers
      #
      # Special values:
      #   - nil (env var not set) -> all passes enabled (production default)
      #   - "*" -> all passes enabled
      #   - "" (empty string) -> no passes enabled (useful for baseline testing)
      def parse(spec)
        # nil means env var not set -> enable all (production default)
        return ALL_PASSES.to_set if spec.nil?

        # Empty string means explicitly disabled all passes
        return Set.new if spec.strip.empty?

        passes = Set.new
        parts = spec.split(",").map(&:strip)

        parts.each do |part|
          next if part.empty?

          if part == "*"
            ALL_PASSES.each { |i| passes << i }
          elsif part.start_with?("-")
            passes.delete(part[1..].to_i)
          else
            passes << part.to_i
          end
        end

        passes
      end

      # Get the current enabled passes (from LIQUID_PASSES env var)
      # This is computed once at boot time and cached
      #
      # @return [Set<Integer>] Set of enabled pass numbers
      def enabled
        @enabled ||= parse(ENV["LIQUID_PASSES"]).freeze
      end

      # Check if a specific pass is enabled
      #
      # @param pass_number [Integer] The pass number to check
      # @return [Boolean] true if the pass is enabled
      def enabled?(pass_number)
        enabled.include?(pass_number)
      end

      # Reset the enabled passes (useful for testing)
      # @api private
      def reset!
        @enabled = nil
      end

      # Temporarily override enabled passes for a block (useful for testing)
      # @api private
      def with_passes(spec)
        old_enabled = @enabled
        @enabled = parse(spec).freeze
        yield
      ensure
        @enabled = old_enabled
      end
    end

    # Boot-time computation of enabled passes
    # Stored as a constant for maximum performance (Ruby can inline constant access)
    ENABLED = parse(ENV["LIQUID_PASSES"]).freeze
  end
end
