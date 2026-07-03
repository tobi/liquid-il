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
end
