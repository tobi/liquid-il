#!/usr/bin/env ruby
# frozen_string_literal: true

# LiquidIL adapter for liquid-spec
# Uses the ruby compiler which generates YJIT-friendly Ruby.

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"

  # Mock Time.now to return frozen time for date filter tests
  # liquid-spec expects time frozen to 2024-01-01 00:01:58 UTC
  module TimeMock
    def now
      Time.new(2024, 1, 1, 0, 1, 58, "+00:00")
    end
  end
  Time.singleton_class.prepend(TimeMock)

  # Shopify filters used by liquid-spec shopify_* suites
  LiquidIL::Filters.singleton_class.class_eval do
    def asset_url(input)
      "/files/1/[shop_id]/[shop_id]/assets/#{input}"
    end

    def img_url(input, size = nil)
      return "" unless input
      if input.is_a?(Hash) || (input.respond_to?(:[]) && !input.is_a?(String))
        url = input["src"] || input.to_s
      else
        url = input.to_s
      end
      if size && size != "original"
        "/assets/#{url.split("/").last.sub(/\.(\w+)\z/, "_#{size}.\\1")}"
      else
        "/assets/#{url.split("/").last}"
      end
    end

    def image_url(input, width: nil, height: nil, crop: nil, format: nil)
      return "" unless input
      url = input.is_a?(String) ? input : (input.respond_to?(:[]) ? (input["src"] || input.to_s) : input.to_s)
      params = []
      params << "width=#{width}" if width
      params << "height=#{height}" if height
      params << "crop=#{crop}" if crop
      params << "format=#{format}" if format
      params.empty? ? url.to_s : "#{url}&#{params.join("&")}"
    end

    def product_img_url(input, size = nil)
      return "" unless input
      url = input.is_a?(Hash) ? (input["url"] || input["src"] || "") : input.to_s
      base = if size && size != "original"
               url.sub(/\.(\w+)\z/, "_#{size}.\\1")
             else
               url
             end
      "/files/shops/random_number/#{base}"
    end

    def stylesheet_tag(url)
      %(<link href="#{url}" rel="stylesheet" type="text/css"  media="all"  />)
    end

    def script_tag(url)
      %(<script src="#{url}" type="text/javascript"></script>)
    end

    def money(input)
      return "$0.00" if input.nil?
      cents = to_number(input)
      "$#{"%.2f" % (cents / 100.0)}"
    end

    def money_with_currency(input)
      "#{money(input)} USD"
    end

    def money_without_trailing_zeros(input)
      money(input).sub(/\.00$/, "")
    end

    def json(input)
      require "json"
      JSON.generate(input)
    end

    def handle(input)
      LiquidIL::Utils.to_s(input).downcase.gsub(/['']/, "").gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    end

    def handleize(input)
      handle(input)
    end

    def pluralize(input, singular, plural)
      input.to_i == 1 ? singular : plural
    end

    def weight_with_unit(input, unit_system = "metric")
      grams = to_number(input)
      kg = grams / 1000.0
      "#{sprintf("%.2f", kg)} kg"
    end

    def default_pagination(paginate)
      return "" unless paginate.is_a?(Hash)
      parts = []
      if paginate["previous"]
        parts << %(<span class="prev"><a href="#{paginate["previous"]["url"]}">&laquo; Previous</a></span>)
      end
      if paginate["parts"]
        paginate["parts"].each do |part|
          if part.is_a?(Hash) && part["is_link"]
            parts << %(<span class="page"><a href="#{part["url"]}">#{part["title"]}</a></span>)
          elsif part.is_a?(Hash)
            parts << %(<span class="page current">#{part["title"]}</span>)
          else
            parts << %(<span class="deco">#{part}</span>)
          end
        end
      end
      if paginate["next"]
        parts << %(<span class="next"><a href="#{paginate["next"]["url"]}">Next &raquo;</a></span>)
      end
      parts.join(" ")
    end

    def t(input, *args)
      input.to_s
    end

    def placeholder_svg_tag(type)
      %(<svg xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%"/></svg>)
    end

    def color_to_rgb(input) = input.to_s
    def color_to_hsl(input) = input.to_s
    def color_modify(input, *args) = input.to_s
    def color_brightness(input) = 128
    def brightness_difference(*args) = 0
    def color_contrast(*args) = 1.0
    def font_face(*args) = ""
    def font_url(font, *args) = font.to_s
    def font_modify(font, *args) = font
    def time_tag(input, *args) = "<time>#{input}</time>"
  end

  LiquidIL::Filters.instance_variable_set(:@valid_filter_methods, nil)
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.features = LiquidSpec::FEATURES.keys
end

# Fallback for templates that can't be compiled (dynamic partials, recursion, etc.)
class FallbackTemplate
  def initialize(error)
    @error = error
  end

  def render(assigns = {}, render_errors: true, **_)
    if render_errors
      case @error
      when LiquidIL::SyntaxError
        "Liquid syntax error (line #{@error.line}): #{@error.message}"
      else
        ""
      end
    else
      raise @error
    end
  end
end

LiquidSpec.compile do |ctx, source, compile_options|
  context = LiquidIL::Context.new(
    file_system: compile_options[:file_system],
    registers: compile_options[:registers],
    strict_errors: compile_options[:strict_errors]
  )

  ctx[:context] = context
  begin
    ctx[:template] = context.parse(source)
  rescue LiquidIL::SyntaxError => e
    # Let syntax errors propagate — liquid-spec runner detects them as parse_error
    raise
  rescue => e
    ctx[:template] = FallbackTemplate.new(e)
  end
end

LiquidSpec.render do |ctx, assigns, render_options|
  strict_errors = render_options.fetch(:strict_errors, false)
  render_errors = !strict_errors
  ctx[:template].render(assigns, render_errors: render_errors)
end
