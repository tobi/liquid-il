# frozen_string_literal: true

require "minitest/autorun"
require "weakref"
require_relative "../lib/liquid_il"

class RuntimeHelpersTest < Minitest::Test
  class EphemeralFileSystem
    def read_template_file(name, _context = nil)
      "partial:#{name}"
    end
  end

  class HashLikeDrop
    include Enumerable

    def each
      yield("first", 1)
      yield("second", 2)
    end
  end

  def test_partial_reader_cache_does_not_retain_file_systems
    reference = cache_ephemeral_file_system

    10.times do
      GC.start(full_mark: true, immediate_sweep: true)
      break unless reference.weakref_alive?
    end

    refute_predicate(reference, :weakref_alive?)
  end

  def test_to_iterable_matches_one_argument_each_semantics_for_hash_like_drops
    assert_equal(["first", "second"], LiquidIL::RuntimeHelpers.to_iterable(HashLikeDrop.new))
  end

  private

  def cache_ephemeral_file_system
    file_system = EphemeralFileSystem.new
    assert_equal("partial:card", LiquidIL::RuntimeHelpers.read_partial_source(file_system, "card"))
    WeakRef.new(file_system)
  end
end
