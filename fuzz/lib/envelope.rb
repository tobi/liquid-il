# frozen_string_literal: true

module Fuzz
  # Enforces the in-process coexistence envelope (goal 02 doc, "The hardest
  # part #1"): LiquidIL's core_ext.rb monkeypatches Object#to_liquid to RAISE
  # for anything that hasn't opted into the Liquid protocol, while giving
  # String/Symbol/Numeric/NilClass/TrueClass/FalseClass/Array/Hash/Range/
  # Time/Date/DateTime an identity to_liquid. Reference `liquid` calls
  # value.to_liquid too -- for every type in that identity list, that's
  # exactly what reference would have done anyway, so both engines can share
  # a process. Outside that type list, our patches change reference's
  # observable behavior (it would raise where clean reference would not) --
  # a false signal, not a real bug.
  #
  # This is why the generator's value pool is restricted to JSON-able,
  # identity-covered types, and why every generated environment MUST be
  # checked with #assert! before either engine touches it -- this is a
  # correctness requirement, not a serialization nicety.
  module Envelope
    class Violation < StandardError; end

    SCALARS = [String, Integer, Float, NilClass, TrueClass, FalseClass].freeze

    def self.assert!(value, path = "$")
      case value
      when *SCALARS
        nil
      when Array
        value.each_with_index { |v, i| assert!(v, "#{path}[#{i}]") }
      when Hash
        value.each do |k, v|
          raise Violation, "#{path}: hash key #{k.inspect} (#{k.class}) is not a String" unless k.is_a?(String)

          assert!(v, "#{path}[#{k.inspect}]")
        end
      else
        raise Violation, "#{path}: value #{value.inspect} (#{value.class}) is not identity-covered/JSON-able"
      end
    end

    def self.safe?(value)
      assert!(value)
      true
    rescue Violation
      false
    end
  end
end
