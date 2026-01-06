# frozen_string_literal: true

require "cgi"
require "uri"
require "date"
require "json"

module LiquidIL
  module Filters
    class << self
      def apply(name, input, args, context)
        method_name = name.to_s.downcase
        if respond_to?(method_name, true)
          send(method_name, input, *args)
        else
          input  # Unknown filter, return input unchanged
        end
      rescue => e
        context.strict_errors ? raise(e) : input
      end

      private

      # --- String filters ---

      def append(input, str)
        "#{input}#{str}"
      end

      def prepend(input, str)
        "#{str}#{input}"
      end

      def capitalize(input)
        input.to_s.capitalize
      end

      def downcase(input)
        input.to_s.downcase
      end

      def upcase(input)
        input.to_s.upcase
      end

      def strip(input)
        input.to_s.strip
      end

      def lstrip(input)
        input.to_s.lstrip
      end

      def rstrip(input)
        input.to_s.rstrip
      end

      def strip_html(input)
        str = input.to_s
        # Remove script and style tags with their content
        str = str.gsub(/<script[^>]*>.*?<\/script>/mi, "")
        str = str.gsub(/<style[^>]*>.*?<\/style>/mi, "")
        # Remove all other HTML tags
        str.gsub(/<[^>]*>/, "")
      end

      def strip_newlines(input)
        input.to_s.gsub(/\r?\n/, "")
      end

      def newline_to_br(input)
        input.to_s.gsub(/\r?\n/, "<br />\n")
      end

      def replace(input, search, replace_str = "")
        input.to_s.gsub(search.to_s, replace_str.to_s)
      end

      def replace_first(input, search, replace_str = "")
        input.to_s.sub(search.to_s, replace_str.to_s)
      end

      def replace_last(input, search, replace_str = "")
        str = input.to_s
        idx = str.rindex(search.to_s)
        return str unless idx
        str[0...idx] + replace_str.to_s + str[(idx + search.to_s.length)..-1]
      end

      def remove(input, search)
        input.to_s.gsub(search.to_s, "")
      end

      def remove_first(input, search)
        input.to_s.sub(search.to_s, "")
      end

      def remove_last(input, search)
        replace_last(input, search, "")
      end

      def truncate(input, length = 50, ellipsis = "...")
        str = input.to_s
        length = length.to_i
        ellipsis = ellipsis.to_s
        return str if str.length <= length
        str[0, [length - ellipsis.length, 0].max] + ellipsis
      end

      def truncatewords(input, words = 15, ellipsis = "...")
        words = [words.to_i, 1].max  # At least 1 word
        ellipsis = ellipsis.to_s
        word_list = input.to_s.split
        return input.to_s if word_list.length <= words
        word_list[0, words].join(" ") + ellipsis
      end

      def split(input, delimiter = " ")
        input.to_s.split(delimiter.to_s)
      end

      def slice(input, start, length = 1)
        str = input.to_s
        start = start.to_i rescue 0
        length = length.to_i rescue str.length
        str[start, length] || ""
      rescue RangeError
        ""
      end

      def escape(input)
        CGI.escapeHTML(input.to_s)
      end

      def escape_once(input)
        CGI.escapeHTML(CGI.unescapeHTML(input.to_s))
      end

      def url_encode(input)
        URI.encode_www_form_component(input.to_s)
      end

      def url_decode(input)
        URI.decode_www_form_component(input.to_s)
      end

      def base64_encode(input)
        [input.to_s].pack("m0")
      end

      def base64_decode(input)
        input.to_s.unpack1("m0").force_encoding("UTF-8")
      rescue ArgumentError
        input.to_s
      end

      def base64_url_safe_encode(input)
        [input.to_s].pack("m0").tr("+/", "-_")
      end

      def base64_url_safe_decode(input)
        str = input.to_s.tr("-_", "+/")
        str += "=" * (4 - str.length % 4) % 4
        str.unpack1("m0").force_encoding("UTF-8")
      rescue ArgumentError
        input.to_s
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
        case input
        when Array, Hash, String
          input.length
        else
          0
        end
      end

      def first(input)
        case input
        when Array then input.first
        when Hash
          pair = input.first
          pair ? "#{pair[0]}#{pair[1]}" : nil
        when String then input.empty? ? nil : input[0]
        else nil
        end
      end

      def last(input)
        case input
        when Array then input.last
        when Hash then nil  # Hashes don't support last filter
        when String then input.empty? ? nil : input[-1]
        else nil
        end
      end

      def join(input, separator = " ")
        return input.to_s unless input.is_a?(Array)
        input.map { |item| liquidize(item).to_s }.join(separator.to_s)
      end

      def reverse(input)
        input.is_a?(Array) ? input.reverse : input.to_s.reverse
      end

      def sort(input, property = nil)
        return [] unless input.is_a?(Array)
        if property
          input.sort_by { |item| lookup_property(item, property).to_s }
        else
          input.sort_by(&:to_s)
        end
      end

      def sort_natural(input, property = nil)
        return [] unless input.is_a?(Array)
        if property
          input.sort_by { |item| lookup_property(item, property).to_s.downcase }
        else
          input.sort_by { |item| item.to_s.downcase }
        end
      end

      def uniq(input, property = nil)
        return [] unless input.is_a?(Array)
        if property
          input.uniq { |item| lookup_property(item, property) }
        else
          input.uniq
        end
      end

      def compact(input, property = nil)
        return input unless input.is_a?(Array)
        if property
          input.reject { |item| lookup_property(item, property).nil? }
        else
          input.compact
        end
      end

      def concat(input, other)
        return [] unless input.is_a?(Array)
        other_arr = other.is_a?(Array) ? other : [other]
        input + other_arr
      end

      def map(input, property)
        return [] unless input.is_a?(Array)
        input.map { |item| lookup_property(item, property) }
      end

      def where(input, property, value = nil)
        return [] unless input.is_a?(Array)
        if value.nil?
          input.select { |item| truthy?(lookup_property(item, property)) }
        else
          input.select { |item| lookup_property(item, property) == value }
        end
      end

      def sum(input, property = nil)
        return 0 unless input.is_a?(Array)
        if property
          input.sum { |item| to_number(lookup_property(item, property)) }
        else
          input.sum { |item| to_number(item) }
        end
      end

      def has(input, property, value = nil)
        return false unless input.is_a?(Array)
        if value.nil?
          input.any? { |item| truthy?(lookup_property(item, property)) }
        else
          input.any? { |item| lookup_property(item, property) == value }
        end
      end

      # --- Date filters ---

      def date(input, format)
        return "" if input.nil?
        strftime_format = format.to_s
        return input.to_s if strftime_format.empty?
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

        if allow_false
          input.nil? ? default_value : input
        else
          default_truthy?(input) ? input : default_value
        end
      end

      def json(input)
        JSON.generate(input)
      rescue
        input.to_s
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
        when Integer, Float
          value
        when String
          if value =~ /\A-?\d+\z/
            value.to_i
          elsif value =~ /\A-?\d+\.\d+\z/
            value.to_f
          else
            0
          end
        when nil
          0
        else
          0
        end
      end

      def lookup_property(obj, key)
        case obj
        when Hash
          result = obj[key.to_s]
          return result unless result.nil?
          key.is_a?(String) ? obj[key.to_sym] : nil
        when Array
          obj[key.to_i] if key.to_s =~ /\A\d+\z/
        else
          obj.respond_to?(:[]) ? (obj[key.to_s] rescue nil) : nil
        end
      end

      def truthy?(value)
        !value.nil? && value != false
      end

      # For default filter - also treats empty strings/arrays as falsy
      def default_truthy?(value)
        return false if value.nil? || value == false
        return false if value == ""
        return false if value.respond_to?(:empty?) && value.empty?
        true
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
  end
end
