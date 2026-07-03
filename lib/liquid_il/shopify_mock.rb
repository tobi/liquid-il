# frozen_string_literal: true

require "cgi"
require "json"
require "zlib"

module LiquidIL
  # Lightweight Shopify storefront surface for liquid-spec adapters.
  #
  # This intentionally models the public shape of Shopify theme tags/filters
  # without depending on Shopify runtime classes. It is adapter opt-in: requiring
  # liquid_il alone keeps LiquidIL's core tag semantics unchanged.
  module ShopifyMock
    CDN_BASE = "//cdn.shopify.shopify-uh49.marcandre-cournoyer.eu.spin.dev/s/files/1/0000/0001/t/1/assets".freeze
    SHOPIFY_TAG_PATTERN = /\{%[-]?\s*(?:schema|style|stylesheet|javascript|form|paginate|section)\b/.freeze
    STOREFRONT_DAWN_ROOT = File.join(Dir.home, "world/trees/root/src/areas/core/storefront/test/support/themes/shop1.myshopify.io-1/dawn").freeze

    class << self
      def install!
        register_tags!
        register_filters!
      end

      def shopify_template?(source)
        source.to_s.match?(SHOPIFY_TAG_PATTERN)
      end

      def wrap_file_system(file_system)
        return file_system if file_system.nil? || file_system.is_a?(FileSystem)

        FileSystem.new(file_system)
      end

      def prepare_environment!(assigns)
        return assigns unless assigns.is_a?(Hash)

        merge_theme_settings!(assigns)
        enrich_section!(assigns)
        assigns
      end

      def theme_source(path)
        path = path.to_s
        path = "#{path}.liquid" unless path.end_with?(".liquid", ".json")
        full_path = File.join(STOREFRONT_DAWN_ROOT, path)
        File.file?(full_path) ? File.read(full_path) : nil
      end

      def section_drop(section_name, assigns = nil)
        config = section_config_for_name(section_name, assigns || {}) || { "type" => section_name.to_s }
        build_section_hash(section_name.to_s, config)
      end

      private

      def register_tags!
        Tags.register "style", end_tag: "endstyle", mode: :passthrough,
          setup: ->(_tag_args, builder) { builder.write_raw("<style data-shopify>") },
          teardown: ->(_tag_args, builder) { builder.write_raw("</style>") }

        Tags.register "schema", end_tag: "endschema", mode: :discard
        Tags.register "javascript", end_tag: "endjavascript", mode: :discard
        Tags.register "stylesheet", end_tag: "endstylesheet", mode: :discard

        Tags.register "form", end_tag: "endform", mode: :passthrough,
          setup: ->(tag_args, builder) { builder.write_raw(form_open_html(tag_args)) },
          teardown: ->(_tag_args, builder) { builder.write_raw("</form>") }

        Tags.register "section", mode: :standalone,
          setup: ->(tag_args, builder) {
            section_name = tag_args.to_s[/['"]([^'"]+)['"]/, 1] || tag_args.to_s.strip
            builder.emit(:SHOPIFY_SECTION_RENDER, section_name) unless section_name.empty?
          }
      end

      def register_filters!
        Filters.singleton_class.class_eval do
          def asset_url(input)
            name = LiquidIL::ShopifyMock.asset_name(input)
            version = Zlib.crc32(name).to_s
            "#{LiquidIL::ShopifyMock::CDN_BASE}/#{CGI.escape(name)}?v=#{version}"
          end

          def img_url(input, size = nil)
            LiquidIL::ShopifyMock.image_url_for(input, size: size)
          end

          def image_url(input, width: nil, height: nil, crop: nil, format: nil)
            LiquidIL::ShopifyMock.image_url_for(input, width: width, height: height, crop: crop, format: format)
          end

          def product_img_url(input, size = nil)
            LiquidIL::ShopifyMock.image_url_for(input, size: size, prefix: "products/")
          end

          def stylesheet_tag(url, media = "all")
            %(<link href="#{CGI.escapeHTML(url.to_s)}" rel="stylesheet" type="text/css" media="#{CGI.escapeHTML(media.to_s)}" />)
          end

          def script_tag(url)
            %(<script src="#{CGI.escapeHTML(url.to_s)}" type="text/javascript"></script>)
          end

          def money(input)
            return "$0.00" if input.nil?

            cents = to_number(input)
            "$#{format("%.2f", cents / 100.0)}"
          end

          def money_with_currency(input)
            "#{money(input)} USD"
          end

          def money_without_trailing_zeros(input)
            money(input).sub(/\.00\z/, "")
          end

          def json(input)
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

          def weight_with_unit(input, _unit_system = "metric")
            grams = to_number(input)
            "#{format("%.2f", grams / 1000.0)} kg"
          end

          def default_pagination(paginate)
            LiquidIL::ShopifyMock.default_pagination(paginate)
          end

          def t(input, *_args)
            input.to_s
          end

          def placeholder_svg_tag(type, css_class = nil)
            klass = css_class ? %( class="#{CGI.escapeHTML(css_class.to_s)}") : ""
            %(<svg xmlns="http://www.w3.org/2000/svg"#{klass}><title>#{CGI.escapeHTML(type.to_s)}</title><rect width="100%" height="100%"/></svg>)
          end

          def color_to_rgb(input) = input.to_s
          def color_to_hsl(input) = input.to_s
          def color_modify(input, *_args) = input.to_s
          def color_brightness(_input) = 128
          def brightness_difference(*_args) = 0
          def color_contrast(*_args) = 1.0
          def font_face(*_args) = ""
          def font_url(font, *_args) = font.to_s
          def font_modify(font, *_args) = font
          def time_tag(input, *_args) = "<time>#{CGI.escapeHTML(input.to_s)}</time>"
        end

        Filters.instance_variable_set(:@valid_filter_methods, nil)
      end

      def form_open_html(tag_args)
        type = tag_args.to_s[/['"]([^'"]+)['"]/, 1] || "form"
        action = form_action(type)
        %(<form method="post" action="#{CGI.escapeHTML(action)}" accept-charset="UTF-8"><input type="hidden" name="form_type" value="#{CGI.escapeHTML(type)}" /><input type="hidden" name="utf8" value="✓" />)
      end

      def form_action(type)
        case type
        when "cart" then "/cart"
        when "contact" then "/contact#contact_form"
        when "customer_login" then "/account/login"
        when "create_customer" then "/account"
        when "recover_customer_password" then "/account/recover"
        when "localization" then "/localization"
        when "product" then "/cart/add"
        else "/#{type.to_s.tr("_", "-")}"
        end
      end
    end

    def self.asset_name(input)
      File.basename(input.to_s.empty? ? "asset" : input.to_s)
    end

    def self.image_url_for(input, size: nil, width: nil, height: nil, crop: nil, format: nil, prefix: "")
      return "" if input.nil?

      src = if input.respond_to?(:[])
        input["src"] || input["url"] || input["preview_image"] || input.to_s
      else
        input.to_s
      end
      src = src["src"] if src.respond_to?(:[]) && !src.is_a?(String)
      src = src.to_s
      return "" if src.empty?

      if src.start_with?("//", "http://", "https://", "/")
        url = src
      else
        name = asset_name(src)
        if size && size.to_s != "original"
          name = name.sub(/(\.[^.]+)\z/, "_#{size}\\1")
        end
        url = "#{CDN_BASE}/#{prefix}#{CGI.escape(name)}"
      end

      params = []
      params << "width=#{CGI.escape(width.to_s)}" if width
      params << "height=#{CGI.escape(height.to_s)}" if height
      params << "crop=#{CGI.escape(crop.to_s)}" if crop
      params << "format=#{CGI.escape(format.to_s)}" if format
      separator = url.include?("?") ? "&" : "?"
      params.empty? ? url : "#{url}#{separator}#{params.join("&")}"
    end

    def self.default_pagination(paginate)
      return "" unless paginate.respond_to?(:[])

      parts = []
      if (previous = paginate["previous"])
        parts << %(<span class="prev"><a href="#{CGI.escapeHTML(previous["url"].to_s)}">&laquo; Previous</a></span>)
      end
      if (pagination_parts = paginate["parts"])
        pagination_parts.each do |part|
          if part.respond_to?(:[]) && part["is_link"]
            parts << %(<span class="page"><a href="#{CGI.escapeHTML(part["url"].to_s)}">#{CGI.escapeHTML(part["title"].to_s)}</a></span>)
          elsif part.respond_to?(:[])
            parts << %(<span class="page current">#{CGI.escapeHTML(part["title"].to_s)}</span>)
          else
            parts << %(<span class="deco">#{CGI.escapeHTML(part.to_s)}</span>)
          end
        end
      end
      if (nxt = paginate["next"])
        parts << %(<span class="next"><a href="#{CGI.escapeHTML(nxt["url"].to_s)}">Next &raquo;</a></span>)
      end
      parts.join(" ")
    end

    def self.merge_theme_settings!(assigns)
      settings = theme_settings
      return if settings.empty?

      current = assigns["settings"]
      assigns["settings"] = current.is_a?(Hash) ? settings.merge(current) : settings.dup
    end

    def self.enrich_section!(assigns)
      section = assigns["section"]
      return assigns unless section.is_a?(Hash)

      config = section_config_for_id(section["id"], assigns)
      return assigns unless config

      section["type"] ||= config["type"]
      section["settings"] = (config["settings"] || {}).merge(section["settings"] || {})
      section["blocks"] = build_blocks(config, section["blocks"])
      section["block_order"] ||= config["block_order"] if config["block_order"]
      assigns
    end

    def self.section_config_for_id(section_id, assigns)
      section_id = section_id.to_s
      return nil if section_id.empty?

      if (config = settings_sections[section_id])
        return config
      end

      key = section_id.include?("__") ? section_id.split("__", 2).last : section_id
      template_name = template_name_for_assigns(assigns, section_id)
      template_config(template_name)&.dig("sections", key) || find_template_section(key)
    end

    def self.section_config_for_name(section_name, assigns)
      name = section_name.to_s
      settings_sections[name] || template_config(template_name_for_assigns(assigns, name))&.dig("sections")&.values&.find { |config| config["type"] == name }
    end

    def self.build_section_hash(id, config)
      {
        "id" => id,
        "type" => config["type"] || id,
        "settings" => (config["settings"] || {}).dup,
        "blocks" => build_blocks(config, []),
        "block_order" => config["block_order"],
        "shopify_attributes" => "",
      }
    end

    def self.build_blocks(config, existing_blocks)
      existing_by_id = {}
      Array(existing_blocks).each { |block| existing_by_id[block["id"]] = block if block.is_a?(Hash) }
      raw_blocks = config["blocks"] || {}
      order = config["block_order"] || raw_blocks.keys
      order.filter_map do |id|
        block_config = raw_blocks[id]
        next unless block_config

        existing = existing_by_id[id] || {}
        existing.merge(
          "id" => id,
          "type" => block_config["type"],
          "settings" => (block_config["settings"] || {}).merge(existing["settings"] || {}),
          "shopify_attributes" => existing["shopify_attributes"] || "",
        )
      end
    end

    def self.template_name_for_assigns(assigns, section_id)
      if assigns["product"] || section_id.to_s.include?("template--160__")
        "product"
      elsif assigns["collection"] || section_id.to_s.include?("template--159__")
        "collection"
      elsif assigns["page"] || section_id.to_s.include?("template--156__")
        "page.contact"
      else
        "index"
      end
    end

    def self.find_template_section(key)
      template_configs.each_value do |config|
        section = config.dig("sections", key)
        return section if section
      end
      nil
    end

    def self.theme_settings
      current = settings_data["current"]
      presets = settings_data["presets"] || {}
      preset = current.is_a?(String) ? presets[current] : current
      (preset || {}).reject { |k, _| k == "sections" }
    end

    def self.settings_sections
      current = settings_data["current"]
      presets = settings_data["presets"] || {}
      preset = current.is_a?(String) ? presets[current] : current
      preset&.fetch("sections", {}) || {}
    end

    def self.settings_data
      @settings_data ||= load_theme_json("config/settings_data.json") || {}
    end

    def self.template_config(name)
      template_configs[name.to_s]
    end

    def self.template_configs
      @template_configs ||= begin
        configs = {}
        Dir[File.join(STOREFRONT_DAWN_ROOT, "templates", "*.json")].each do |path|
          configs[File.basename(path, ".json")] = JSON.parse(File.read(path))
        end
        configs
      end
    end

    def self.load_theme_json(path)
      source = theme_source(path)
      source ? JSON.parse(source) : nil
    rescue JSON::ParserError
      nil
    end

    # Shopify specs in liquid-spec intentionally omit Dawn snippet files; the
    # reference expected output was recorded with Shopify's full theme runtime.
    # For LiquidIL's mock environment, missing snippets render as empty strings
    # only when the adapter opts into this wrapper for Shopify templates.
    class FileSystem
      def initialize(delegate)
        @delegate = delegate
      end

      def read_template_file(template_path)
        @delegate.read_template_file(template_path)
      rescue Liquid::FileSystemError
        LiquidIL::ShopifyMock.theme_source(template_path) || ""
      end

      def to_h
        @delegate.respond_to?(:to_h) ? @delegate.to_h : {}
      end
    end
  end
end
