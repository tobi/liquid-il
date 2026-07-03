# frozen_string_literal: true

# Liquid protocol: every object has a Liquid representation.
# Object#to_liquid returns self by default; drops and Liquid-aware types
# override it to return a safe hash/drop/value. This lets the compiler
# and runtime call to_liquid/to_liquid_value unconditionally without
# respond_to? checks, eliminating a class of bugs where drops aren't
# unwrapped in some code paths.
#
# Guarded with method_defined? so we don't overwrite existing definitions
# (e.g., from the liquid gem or user code).

class Object
  unless method_defined?(:to_liquid)
    def to_liquid
      self
    end
  end

  unless method_defined?(:to_liquid_value)
    def to_liquid_value
      self
    end
  end

  # Liquid stringification — converts any value to its Liquid string
  # representation. Override for types with special rendering (Hash, Array, Drops).
  # Default: call to_liquid then to_s.
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
