# frozen_string_literal: true

module LiquidIL
  class RubyCompiler
    # Output and truthiness policy driven only by CodeFragment metadata.
    module OutputEmitter
    def inline_output_append(expression, prefix, guard_interrupt: false)
      fragment = CodeFragment.wrap(expression)
      source = fragment.source

      if fragment.cache_filter && (cache_var = FilterEmitter::FILTER_CACHE[fragment.cache_filter])
        require_filter_cache(cache_var)
        input = fragment.cache_input
        source = "(#{cache_var}[(_v = #{input}.to_liquid_s)] || (#{cache_var}[_v] = _v.#{fragment.cache_filter}))"
      end

      statement = case fragment.output_policy
      when :direct
        "#{prefix}_O << #{source}"
      when :to_s
        "#{prefix}_O << (#{source}.to_s)"
      else
        "#{prefix}_H.oa(_O, #{source})"
      end
      statement << " unless _S.has_interrupt?" if guard_interrupt
      statement << "\n"
    end

    # Generate an inline truthy check expression (avoids lambda call overhead)
    # Uses || false to handle nil → false conversion, matching Liquid truthy semantics
    def inline_truthy(expression)
      fragment = CodeFragment.wrap(expression)
      if fragment.value_type == :boolean
        "(#{fragment.source})"
      else
        # Unwrap drops via to_liquid_value (BooleanDrop with false should be
        # falsy). Unknown values retain the full Liquid truthiness contract.
        "_H.t(#{fragment.source})"
      end
    end

    end
  end
end
