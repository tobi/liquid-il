# frozen_string_literal: true

# Liquid protocol: every object responds to to_liquid/to_liquid_value —
# call sites invoke them unconditionally, never respond_to?-check. The
# DEFAULT raises: a plain object that never opted into the protocol fails
# loudly (LiquidIL::NoMethodError, matching reference liquid's genuine
# NoMethodError) the moment a template touches it, instead of silently
# leaking or hiding. That raise is the drop-protocol security boundary
# (see liquid-spec's security_drops suite). Liquid-safe core types and
# drops opt in via IdentityToLiquid or their own overrides.
#
# Guarded with method_defined? so we don't overwrite existing definitions
# (e.g., from the liquid gem or user code).

module LiquidIL
  # Mixin for classes that are Liquid-safe as themselves.
  module IdentityToLiquid
    def to_liquid
      self
    end

    def to_liquid_value
      self
    end
  end
end

[String, Symbol, Numeric, NilClass, TrueClass, FalseClass,
 Array, Hash, Range, Time, defined?(Date) && Date, defined?(DateTime) && DateTime].each do |klass|
  klass.include(LiquidIL::IdentityToLiquid) if klass && !klass.method_defined?(:to_liquid)
end

class Object
  unless method_defined?(:to_liquid)
    def to_liquid
      raise LiquidIL::NoMethodError, "undefined method 'to_liquid' for an instance of #{self.class}"
    end
  end

  unless method_defined?(:to_liquid_value)
    # Identity, NOT delegation to to_liquid: to_liquid_value is a LiquidIL
    # extension (drops override it), and reference liquid counts to_liquid
    # invocations observably (stateful drops like liquid-spec's ToSDrop).
    # The protocol raise lives on to_liquid alone.
    def to_liquid_value
      self
    end
  end

  # Liquid stringification — converts any value to its Liquid string
  # representation. Override for types with special rendering (Hash, Array, Drops).
  # Default: call to_liquid then to_s. For non-Liquid objects this raises
  # via to_liquid — same as reference liquid at output time.
  unless method_defined?(:to_liquid_s)
    def to_liquid_s
      v = to_liquid
      v.equal?(self) ? to_s : v.to_liquid_s
    end
  end
end

# Core type overrides for to_liquid_s
class NilClass
  def to_liquid_s; ""; end
end

class TrueClass
  def to_liquid_s; "true"; end
end

class FalseClass
  def to_liquid_s; "false"; end
end

class Integer
  def to_liquid_s; to_s; end
end

class Float
  def to_liquid_s; to_s; end
end

class String
  def to_liquid_s; self; end
end

class Hash
  def to_liquid_s
    LiquidIL::Utils.hash_inspect(self)
  end
end

class Array
  # to_liquid_s produces the inspect format (e.g. [1, "two", nil])
  # matching Liquid's filter stringification behavior.
  # Direct output rendering joins elements via Utils.output_string.
  def to_liquid_s
    LiquidIL::Utils.array_inspect(self)
  end
end
