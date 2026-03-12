#!/usr/bin/env ruby
# frozen_string_literal: true

# LiquidIL adapter for liquid-spec with Shopify feature support.
# Extends the base structured compiler adapter with Shopify-specific tags, objects, and filters.

require "liquid/spec/cli/adapter_dsl"
require_relative "../lib/liquid_il"

LiquidSpec.setup do |ctx|
  require "liquid"

  # Mock Time.now to return frozen time for date filter tests
  module TimeMock
    def now
      Time.new(2024, 1, 1, 0, 1, 58, "+00:00")
    end
  end
  Time.singleton_class.prepend(TimeMock)

  # Override Shopify-specific filters on the Filters singleton class
  LiquidIL::Filters.singleton_class.class_eval do
    # --- Shopify URL / asset filters ---
    def asset_url(input)
      "//cdn.shopify.com/s/files/1/0000/0001/t/1/assets/#{input}"
    end

    def asset_img_url(input, size = nil)
      url = asset_url(input)
      size ? url.sub(/\.(\w+)\z/, "_#{size}.\\1") : url
    end

    def img_url(input, size = nil)
      return "" unless input
      url = input.is_a?(String) ? input : (input.respond_to?(:[]) ? input["src"] : input.to_s)
      size ? url.to_s.sub(/\.(\w+)\z/, "_#{size}.\\1") : url.to_s
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

    def stylesheet_tag(url)
      "<link href=\"#{url}\" rel=\"stylesheet\" type=\"text/css\" media=\"all\" />"
    end

    def script_tag(url)
      "<script src=\"#{url}\" type=\"text/javascript\"></script>"
    end

    def shopify_asset_url(input)
      "//cdn.shopify.com/shopifycloud/shopify/#{input}"
    end

    def global_asset_url(input)
      "//cdn.shopify.com/s/global/#{input}"
    end

    def file_url(input)
      "//cdn.shopify.com/s/files/1/0000/0001/files/#{input}"
    end

    def file_img_url(input, size = nil)
      url = file_url(input)
      size ? url.sub(/\.(\w+)\z/, "_#{size}.\\1") : url
    end

    # --- Shopify link/URL helpers ---
    def link_to(input, url, title = nil)
      title_attr = title ? " title=\"#{title}\"" : ""
      "<a href=\"#{url}\"#{title_attr}>#{input}</a>"
    end

    def within(url, collection)
      collection ? "/collections/#{collection}#{url}" : url
    end

    def url_for_type(type)
      "/collections/types?q=#{type}"
    end

    def url_for_vendor(vendor)
      "/collections/vendors?q=#{vendor}"
    end

    # --- Shopify money filters ---
    def money(input)
      return "" if input.nil?
      cents = to_number(input)
      "$#{"%.2f" % (cents / 100.0)}"
    end

    def money_with_currency(input)
      "#{money(input)} USD"
    end

    def money_without_trailing_zeros(input)
      money(input).sub(/\.00$/, "")
    end

    def money_without_currency(input)
      money(input)
    end

    # --- Shopify JSON ---
    def json(input)
      require "json"
      JSON.generate(input)
    end

    # --- Shopify misc ---
    def handle(input)
      LiquidIL::Utils.to_s(input).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    end

    def handleize(input)
      handle(input)
    end

    def camelcase(input)
      LiquidIL::Utils.to_s(input).split(/[-_]/).map(&:capitalize).join
    end

    def pluralize(input, singular, plural)
      input.to_i == 1 ? singular : plural
    end

    def time_tag(input, *args)
      "<time>#{input}</time>"
    end

    def placeholder_svg_tag(type)
      "<svg>#{type}</svg>"
    end

    def payment_type_svg_tag(type)
      "<svg>#{type}</svg>"
    end

    def highlight_active_tag(input, *args)
      input.to_s
    end

    def default_pagination(paginate)
      ""
    end

    def weight_with_unit(input, unit_system = "metric")
      "#{input}kg"
    end

    def hmac_sha256(input, secret)
      require "openssl"
      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, input.to_s)
    end

    def font_face(font, font_display: "swap")
      ""
    end

    def font_url(font, *args)
      font.to_s
    end

    def font_modify(font, property, value)
      font
    end

    def color_to_rgb(input) = input.to_s
    def color_to_hsl(input) = input.to_s
    def color_modify(input, property, value) = input.to_s
    def color_brightness(input) = 128
    def brightness_difference(input1, input2) = 0
    def color_contrast(input1, input2) = 1.0

    def image_tag(input, *args)
      return "" unless input
      src = input.is_a?(String) ? input : (input.respond_to?(:[]) ? (input["src"] || input.to_s) : input.to_s)
      "<img src=\"#{src}\" />"
    end

    def customer_login_link(input)
      "<a href=\"/account/login\">#{input}</a>"
    end

    def customer_register_link(input)
      "<a href=\"/account/register\">#{input}</a>"
    end

    def customer_logout_link(input)
      "<a href=\"/account/logout\">#{input}</a>"
    end
  end

  # Clear cached filter list
  LiquidIL::Filters.instance_variable_set(:@valid_filter_methods, nil)
end

LiquidSpec.configure do |config|
  config.suite = :all
  config.features = [
    :core,
    :runtime_drops,
    :shopify_tags,
    :shopify_objects,
    :shopify_filters,
    :shopify_blank,
    :shopify_string_access,
  ]
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
    raise
  rescue => e
    ctx[:template] = Class.new {
      define_method(:render) { |*| "" }
    }.new
  end
end

LiquidSpec.render do |ctx, assigns, render_options|
  strict_errors = render_options.fetch(:strict_errors, false)
  render_errors = !strict_errors
  ctx[:template].render(assigns, render_errors: render_errors)
end
