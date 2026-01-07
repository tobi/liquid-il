# frozen_string_literal: true

require "bigdecimal"

module LiquidIL
  module Utils
    HASH_TO_S_METHOD = Hash.instance_method(:to_s)
    HASH_INSPECT_METHOD = Hash.instance_method(:inspect)

    def self.to_s(obj, seen = {})
      case obj
      when BigDecimal
        obj.to_s("F")
      when Hash
        if obj.class.instance_method(:to_s) == HASH_TO_S_METHOD
          hash_inspect(obj, seen)
        else
          obj.to_s
        end
      when Array
        array_inspect(obj, seen)
      else
        obj.to_s
      end
    end

    def self.to_liquid_value(obj)
      obj.respond_to?(:to_liquid_value) ? obj.to_liquid_value : obj
    end

    def self.inspect(obj, seen = {})
      case obj
      when Hash
        if obj.class.instance_method(:inspect) == HASH_INSPECT_METHOD
          hash_inspect(obj, seen)
        else
          obj.inspect
        end
      when Array
        array_inspect(obj, seen)
      else
        obj.inspect
      end
    end

    def self.array_inspect(arr, seen = {})
      return "[...]" if seen[arr.object_id]

      seen[arr.object_id] = true
      str = +"["
      cursor = 0
      len = arr.length

      while cursor < len
        str << ", " if cursor > 0
        str << inspect(arr[cursor], seen)
        cursor += 1
      end

      str << "]"
      str
    ensure
      seen.delete(arr.object_id)
    end

    # Optimized output_string - avoid respond_to? for common types
    # String, Integer, Float are the most common and don't need to_liquid conversion
    def self.output_string(value)
      case value
      when String
        value
      when Integer, Float
        value.to_s
      when nil
        ""
      when true
        "true"
      when false
        "false"
      when RangeValue
        value.to_s
      when Array
        value.map { |item| output_string(item) }.join
      when EmptyLiteral, BlankLiteral
        ""
      else
        # Only check to_liquid for objects that might be Drops
        value = value.to_liquid if value.respond_to?(:to_liquid)
        to_s(value)
      end
    end

    def self.hash_inspect(hash, seen = {})
      return "{...}" if seen[hash.object_id]

      seen[hash.object_id] = true
      str = +"{"
      first = true
      hash.each do |key, value|
        if first
          first = false
        else
          str << ", "
        end

        str << inspect(key, seen)
        str << "=>"
        str << inspect(value, seen)
      end
      str << "}"
      str
    ensure
      seen.delete(hash.object_id)
    end

    private_constant :HASH_TO_S_METHOD, :HASH_INSPECT_METHOD
  end
end
