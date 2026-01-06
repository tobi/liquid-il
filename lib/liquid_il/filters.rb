# frozen_string_literal: true

require "cgi"
require "uri"
require "date"
require "json"
require "base64"

require_relative "utils"

module LiquidIL
  module Filters
    STRIP_HTML_BLOCKS = Regexp.union(
      %r{<script.*?</script>}m,
      /<!--.*?-->/m,
      %r{<style.*?</style>}m
    )
    STRIP_HTML_TAGS = /<.*?>/m
    MIN_I64 = -(1 << 63)
    MAX_I64 = (1 << 63) - 1
    I64_RANGE = MIN_I64..MAX_I64

    class << self
      # Private methods that shouldn't be callable as filters
      INTERNAL_METHODS = %w[to_number to_integer to_safe_integer clamp_i64 strftime_filter apply].freeze

      def apply(name, input, args, context)
        @context = context
        method_name = name.to_s.downcase
        if respond_to?(method_name, true) && !INTERNAL_METHODS.include?(method_name)
          send(method_name, input, *args)
        else
          input  # Unknown filter, return input unchanged
        end
      rescue => e
        context.strict_errors ? raise(e) : input
      ensure
        @context = nil
      end

      private

      # --- String filters ---

      def append(input, str)
        Utils.to_s(input) + Utils.to_s(str)
      end

      def prepend(input, str)
        Utils.to_s(str) + Utils.to_s(input)
      end

      def capitalize(input)
        Utils.to_s(input).capitalize
      end

      def downcase(input)
        Utils.to_s(input).downcase
      end

      def upcase(input)
        Utils.to_s(input).upcase
      end

      def strip(input)
        Utils.to_s(input).strip
      end

      def lstrip(input)
        Utils.to_s(input).lstrip
      end

      def rstrip(input)
        Utils.to_s(input).rstrip
      end

      def strip_html(input)
        str = Utils.to_s(input)
        empty = ""
        result = str.gsub(STRIP_HTML_BLOCKS, empty)
        result.gsub(STRIP_HTML_TAGS, empty)
      end

      def strip_newlines(input)
        Utils.to_s(input).gsub(/\r?\n/, "")
      end

      def newline_to_br(input)
        Utils.to_s(input).gsub(/\r?\n/, "<br />\n")
      end

      def replace(input, search, replace_str = "")
        Utils.to_s(input).gsub(Utils.to_s(search), Utils.to_s(replace_str))
      end

      def replace_first(input, search, replace_str = "")
        Utils.to_s(input).sub(Utils.to_s(search), Utils.to_s(replace_str))
      end

      def replace_last(input, search, replace_str = "")
        str = Utils.to_s(input)
        search_str = Utils.to_s(search)
        idx = str.rindex(search_str)
        return str unless idx
        str[0...idx] + Utils.to_s(replace_str) + str[(idx + search_str.length)..-1]
      end

      def remove(input, search)
        Utils.to_s(input).gsub(Utils.to_s(search), "")
      end

      def remove_first(input, search)
        Utils.to_s(input).sub(Utils.to_s(search), "")
      end

      def remove_last(input, search)
        replace_last(input, search, "")
      end

      def truncate(input, length = 50, ellipsis = "...")
        str = Utils.to_s(input)
        length = length.to_i
        ellipsis = Utils.to_s(ellipsis)
        return str if str.length <= length
        str[0, [length - ellipsis.length, 0].max] + ellipsis
      end

      def truncatewords(input, words = 15, ellipsis = "...")
        words = [words.to_i, 1].max  # At least 1 word
        ellipsis = Utils.to_s(ellipsis)
        input_str = Utils.to_s(input)
        word_list = input_str.split
        return input_str if word_list.length <= words
        word_list[0, words].join(" ") + ellipsis
      end

      def split(input, delimiter = " ")
        Utils.to_s(input).split(Utils.to_s(delimiter))
      end

      def slice(input, start, length = nil)
        start = to_integer(start)
        length = length ? to_integer(length) : 1

        begin
          if input.is_a?(Array)
            input.slice(start, length) || []
          else
            Utils.to_s(input).slice(start, length) || ""
          end
        rescue RangeError
          if I64_RANGE.cover?(length) && I64_RANGE.cover?(start)
            raise
          end
          start = start.clamp(I64_RANGE)
          length = length.clamp(I64_RANGE)
          retry
        end
      end

      def escape(input)
        CGI.escapeHTML(Utils.to_s(input))
      end

      def escape_once(input)
        CGI.escapeHTML(CGI.unescapeHTML(Utils.to_s(input)))
      end

      def url_encode(input)
        URI.encode_www_form_component(Utils.to_s(input))
      end

      def url_decode(input)
        URI.decode_www_form_component(Utils.to_s(input))
      end

      def base64_encode(input)
        Base64.strict_encode64(Utils.to_s(input))
      end

      def base64_decode(input)
        input = Utils.to_s(input)
        try_coerce_encoding(Base64.strict_decode64(input), encoding: input.encoding)
      end

      def base64_url_safe_encode(input)
        Base64.urlsafe_encode64(Utils.to_s(input))
      end

      def base64_url_safe_decode(input)
        input = Utils.to_s(input)
        try_coerce_encoding(Base64.urlsafe_decode64(input), encoding: input.encoding)
      end

      # --- Math filters ---

      def plus(input, operand)
        to_number(input) + to_number(operand)
      end

      def minus(input, operand)
        to_number(input) - to_number(operand)
      end

      def times(input, operand)
        to_number(input) * to_number(operand)
      end

      def divided_by(input, operand)
        divisor = to_number(operand)
        return 0 if divisor == 0
        dividend = to_number(input)
        if dividend.is_a?(Integer) && divisor.is_a?(Integer)
          dividend / divisor
        else
          dividend.to_f / divisor
        end
      end

      def modulo(input, operand)
        to_number(input) % to_number(operand)
      end

      def abs(input)
        to_number(input).abs
      end

      def ceil(input)
        to_number(input).to_f.ceil
      end

      def floor(input)
        to_number(input).to_f.floor
      end

      def round(input, precision = 0)
        to_number(input).to_f.round(precision.to_i)
      end

      def at_least(input, minimum)
        [to_number(input), to_number(minimum)].max
      end

      def at_most(input, maximum)
        [to_number(input), to_number(maximum)].min
      end

      # --- Array filters ---

      def size(input)
        input.respond_to?(:size) ? input.size : 0
      end

      def first(input)
        return input[0] || "" if input.is_a?(String)
        input.first if input.respond_to?(:first)
      end

      def last(input)
        return input[-1] || "" if input.is_a?(String)
        input.last if input.respond_to?(:last)
      end

      def join(input, separator = " ")
        glue = Utils.to_s(separator)
        InputIterator.new(input, context).join(glue)
      end

      def reverse(input)
        InputIterator.new(input, context).reverse
      end

      def sort(input, property = nil)
        ary = InputIterator.new(input, context)
        return [] if ary.empty?

        if property.nil?
          ary.sort { |a, b| nil_safe_compare(a, b) }
        elsif ary.all? { |el| el.respond_to?(:[]) }
          begin
            ary.sort { |a, b| nil_safe_compare(a[property], b[property]) }
          rescue TypeError
            raise_property_error(property)
          end
        end
      end

      def sort_natural(input, property = nil)
        ary = InputIterator.new(input, context)
        return [] if ary.empty?

        if property.nil?
          ary.sort { |a, b| nil_safe_casecmp(a, b) }
        elsif ary.all? { |el| el.respond_to?(:[]) }
          begin
            ary.sort { |a, b| nil_safe_casecmp(a[property], b[property]) }
          rescue TypeError
            raise_property_error(property)
          end
        end
      end

      def where(input, property, value = nil)
        filter_array(input, property, value) { |ary, &block| ary.select(&block) }
      end

      def reject(input, property, value = nil)
        filter_array(input, property, value) { |ary, &block| ary.reject(&block) }
      end

      def has(input, property, value = nil)
        filter_array(input, property, value, false) { |ary, &block| ary.any?(&block) }
      end

      def find(input, property, value = nil)
        filter_array(input, property, value, nil) { |ary, &block| ary.find(&block) }
      end

      def find_index(input, property, value = nil)
        filter_array(input, property, value, nil) { |ary, &block| ary.find_index(&block) }
      end

      def uniq(input, property = nil)
        ary = InputIterator.new(input, context)

        if property.nil?
          ary.uniq
        elsif ary.empty?
          []
        else
          ary.uniq do |item|
            item[property]
          rescue TypeError
            raise_property_error(property)
          rescue NoMethodError
            return nil unless item.respond_to?(:[])
            raise
          end
        end
      end

      def compact(input, property = nil)
        ary = InputIterator.new(input, context)

        if property.nil?
          ary.compact
        elsif ary.empty?
          []
        else
          ary.reject do |item|
            item[property].nil?
          rescue TypeError
            raise_property_error(property)
          rescue NoMethodError
            return nil unless item.respond_to?(:[])
            raise
          end
        end
      end

      def concat(input, other)
        unless other.respond_to?(:to_ary)
          raise ArgumentError, "concat filter requires an array argument"
        end
        InputIterator.new(input, context).concat(other)
      end

      def map(input, property)
        InputIterator.new(input, context).map do |item|
          item = item.call if item.is_a?(Proc)

          if property == "to_liquid"
            item
          elsif item.respond_to?(:[])
            result = item[property]
            result.is_a?(Proc) ? result.call : result
          end
        end
      rescue TypeError
        raise_property_error(property)
      end

      def sum(input, property = nil)
        ary = InputIterator.new(input, context)
        return 0 if ary.empty?

        values = ary.map do |item|
          if property.nil?
            item
          elsif item.respond_to?(:[])
            item[property]
          else
            0
          end
        end

        result = InputIterator.new(values, context).sum { |item| to_number(item) }
        result.is_a?(BigDecimal) ? result.to_f : result
      end

      # --- Date filters ---

      def date(input, format)
        return "" if input.nil?
        strftime_format = Utils.to_s(format)
        return Utils.to_s(input) if strftime_format.empty?
        time = parse_date(input)
        return input unless time
        time.strftime(strftime_format)
      rescue
        input
      end

      # --- Type filters ---

      def default(input, default_value = "", *extra_args)
        # Handle keyword args passed as positional: "allow_false", true
        allow_false = false
        i = 0
        while i < extra_args.length
          if extra_args[i] == "allow_false" && i + 1 < extra_args.length
            allow_false = extra_args[i + 1]
            i += 2
          else
            i += 1
          end
        end

        liquid_value = input.respond_to?(:to_liquid_value) ? input.to_liquid_value : input
        false_check = allow_false ? input.nil? : !liquid_truthy?(liquid_value)
        false_check || (input.respond_to?(:empty?) && input.empty?) ? default_value : input
      end

      def json(input)
        JSON.generate(input)
      rescue
        Utils.to_s(input)
      end

      # --- Utility ---

      def liquidize(value)
        value.respond_to?(:to_liquid) ? value.to_liquid : value
      end

      def to_number(value)
        # Handle drops with to_number method (like NumberLikeThing)
        if value.respond_to?(:to_number)
          return to_number(value.to_number)
        end

        # Handle drops with to_liquid_value
        if value.respond_to?(:to_liquid_value)
          value = value.to_liquid_value
        end

        case value
        when BigDecimal
          value
        when Integer
          value
        when Float
          BigDecimal(value.to_s)
        when String
          # Parse leading numeric part like Ruby's to_i/to_f
          if value.empty?
            0
          elsif value.include?(".")
            # Try to parse as float - handles "6.3", "6-3" (becomes 6.0)
            BigDecimal(value.to_f.to_s)
          else
            value.to_i
          end
        when nil
          0
        else
          0
        end
      end

      def to_integer(value)
        return value if value.is_a?(Integer)

        value = Utils.to_s(value)
        Integer(value)
      rescue ArgumentError
        raise ArgumentError, "invalid integer"
      end

      def liquid_truthy?(value)
        !value.nil? && value != false
      end

      def try_coerce_encoding(input, encoding:)
        original_encoding = input.encoding
        if input.encoding != encoding
          input.force_encoding(encoding)
          input.force_encoding(original_encoding) unless input.valid_encoding?
        end
        input
      end

      def context
        @context
      end

      def nil_safe_compare(a, b)
        result = a <=> b
        if result
          result
        elsif a.nil?
          1
        elsif b.nil?
          -1
        else
          raise ArgumentError, "cannot sort values of incompatible types"
        end
      end

      def nil_safe_casecmp(a, b)
        if !a.nil? && !b.nil?
          a.to_s.casecmp(b.to_s)
        elsif a.nil? && b.nil?
          0
        else
          a.nil? ? 1 : -1
        end
      end

      def raise_property_error(property)
        raise ArgumentError, "cannot select the property '#{Utils.to_s(property)}'"
      end

      def filter_array(input, property, target_value, default_value = [], &block)
        ary = InputIterator.new(input, context)
        return default_value if ary.empty?

        block.call(ary) do |item|
          if target_value.nil?
            item[property]
          else
            item[property] == target_value
          end
        rescue TypeError
          raise_property_error(property)
        rescue NoMethodError
          return nil unless item.respond_to?(:[])
          raise
        end
      end

      def parse_date(input)
        case input
        when Time, DateTime
          input
        when Date
          input.to_time
        when Numeric
          Time.at(input)
        when String
          str = input.downcase
          if str == "now" || str == "today"
            Time.now
          elsif input =~ /\A-?\d+\z/
            # Numeric string - treat as timestamp
            Time.at(input.to_i)
          else
            Time.parse(input)
          end
        else
          nil
        end
      rescue
        nil
      end
    end

    class InputIterator
      include Enumerable

      def initialize(input, context)
        @context = context
        @input = if input.is_a?(Array)
          input.flatten
        elsif input.is_a?(Hash)
          [input]
        elsif input.is_a?(Enumerable)
          input
        else
          Array(input)
        end
      end

      def join(glue)
        first = true
        output = +""
        each do |item|
          if first
            first = false
          else
            output << glue
          end

          output << Utils.to_s(item)
        end
        output
      end

      def concat(args)
        to_a.concat(args)
      end

      def reverse
        reverse_each.to_a
      end

      def uniq(&block)
        to_a.uniq do |item|
          item = Utils.to_liquid_value(item)
          block ? yield(item) : item
        end
      end

      def compact
        to_a.compact
      end

      def empty?
        @input.each { return false }
        true
      end

      def each
        @input.each do |e|
          e = e.to_liquid if e.respond_to?(:to_liquid)
          e.context = @context if @context && e.respond_to?(:context=)
          yield(e)
        end
      end
    end
  end
end
