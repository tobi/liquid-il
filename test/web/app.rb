# frozen_string_literal: true

require "json"
require "rack"
require "time"
require_relative "../../lib/liquid_il"

module LiquidILWeb
  class ThemeFileSystem
    def initialize(root)
      @root = root
    end

    # Liquid-compatible signature. Context is optional and ignored here.
    def read_template_file(name, _context = nil)
      base = name.to_s.sub(/\.liquid\z/, "")
      candidates = [
        File.join(@root, "snippets", "#{base}.liquid"),
        File.join(@root, "templates", "#{base}.liquid"),
      ]
      path = candidates.find { |p| File.file?(p) }
      raise Errno::ENOENT, "No such template: #{name}" unless path

      File.read(path)
    end
  end

  module ShopifyFilters
    module_function

    def asset_url(input)
      "/assets/#{input}"
    end

    def img_url(input, size = nil)
      return "" unless input
      url = if input.is_a?(Hash)
        input["src"] || input[:src] || input.to_s
      else
        input.to_s
      end
      file = File.basename(url)
      return "/images/#{file}" if size.nil? || size == "original"

      "/images/#{file.sub(/\.(\w+)\z/, "_#{size}.\\1")}"
    end

    def product_img_url(input, size = nil)
      img_url(input, size)
    end

    def money(input)
      cents = input.to_f
      format("$%.2f", cents / 100.0)
    end

    def default_pagination(paginate)
      return "" unless paginate.is_a?(Hash)

      parts = []
      if (prev = paginate["previous"])
        parts << %(<a class="page prev" href="#{prev["url"]}">&laquo; Previous</a>)
      end

      (paginate["parts"] || []).each do |part|
        if part.is_a?(Hash) && part["is_link"]
          parts << %(<a class="page" href="#{part["url"]}">#{part["title"]}</a>)
        elsif part.is_a?(Hash)
          parts << %(<span class="page current">#{part["title"]}</span>)
        else
          parts << %(<span class="page">#{part}</span>)
        end
      end

      if (nxt = paginate["next"])
        parts << %(<a class="page next" href="#{nxt["url"]}">Next &raquo;</a>)
      end

      %(<nav class="pagination">#{parts.join(" ")}</nav>)
    end

    def handle(input)
      input.to_s.downcase.gsub(/[']/, "").gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-$/, "")
    end
  end

  class Data
    class << self
      def shop
        { "name" => "LiquidIL Outfitters" }
      end

      def all_products
        @all_products ||= begin
          names = [
            "Synergistic Wooden Car", "Practical Granite Hat", "Aerodynamic Cotton Jacket",
            "Incredible Silk Gloves", "Enormous Bronze Clock", "Intelligent Paper Lamp",
            "Ergonomic Wool Blanket", "Rustic Steel Table", "Futuristic Ceramic Mug",
            "Minimal Leather Backpack", "Cozy Linen Throw", "Premium Hiking Boots",
          ]

          names.each_with_index.map do |name, i|
            price = 1_900 + (i * 375)
            compare = i.even? ? price + 700 : price
            handle = ShopifyFilters.handle(name)
            {
              "id" => 1000 + i,
              "title" => name,
              "url" => "/products/#{handle}",
              "handle" => handle,
              "price" => price,
              "compare_at_price" => compare,
              "featured_image" => "#{handle}.jpg",
              "images" => ["#{handle}.jpg", "#{handle}-alt-1.jpg", "#{handle}-alt-2.jpg"],
              "description" => "#{name} crafted for daily adventures. Durable, stylish, and loved by customers.",
              "vendor" => "LiquidIL Labs",
              "type" => "Gear",
              "tags" => ["new", "featured", "best seller"],
              "variants" => [
                { "id" => 5000 + (i * 10), "title" => "Default", "price" => price, "available" => true },
                { "id" => 5001 + (i * 10), "title" => "Deluxe", "price" => price + 900, "available" => i % 3 != 0 },
              ],
            }
          end
        end
      end

      def collections
        @collections ||= {
          "frontpage" => {
            "title" => "Frontpage",
            "url" => "/collections/all",
            "description" => "A curated set of products from the LiquidIL benchmark universe.",
            "products" => all_products.first(8),
            "products_count" => 8,
          },
          "all" => {
            "title" => "All Products",
            "url" => "/collections/all",
            "description" => "Everything in our synthetic benchmark catalog.",
            "products" => all_products,
            "products_count" => all_products.length,
          },
        }
      end

      def find_product(handle)
        all_products.find { |p| p["handle"] == handle } || all_products.first
      end

      def related_products(current)
        all_products.reject { |p| p["id"] == current["id"] }.first(4)
      end

      def cart
        items = all_products.first(3).map.with_index do |product, i|
          qty = i + 1
          {
            "key" => "line-#{product["id"]}",
            "id" => product["id"],
            "url" => product["url"],
            "title" => product["title"],
            "image" => product["featured_image"],
            "price" => product["price"],
            "quantity" => qty,
            "line_price" => product["price"] * qty,
            "variant_title" => "Default",
          }
        end
        {
          "items" => items,
          "item_count" => items.sum { |i| i["quantity"] },
          "total_price" => items.sum { |i| i["line_price"] },
        }
      end

      def blog
        now = Time.now
        articles = 10.times.map do |i|
          {
            "title" => "LiquidIL Engineering Note ##{i + 1}",
            "url" => "/blogs/news/liquidil-note-#{i + 1}",
            "author" => i.even? ? "Tobi" : "Liquid Bot",
            "published_at" => (now - (i * 86_400)).iso8601,
            "content" => "We tuned parse + render hot paths and validated no regressions across liquid-spec.",
            "image" => { "src" => "blog-#{i + 1}.jpg" },
          }
        end
        { "title" => "Engineering Journal", "articles" => articles }
      end

      def search(terms)
        q = terms.to_s.downcase.strip
        results = if q.empty?
          []
        else
          all_products.select { |p| p["title"].downcase.include?(q) } +
            blog["articles"].select { |a| a["title"].downcase.include?(q) }.map { |a| a.merge("object_type" => "article") }
        end

        {
          "performed" => !q.empty?,
          "terms" => terms.to_s,
          "results" => results,
          "results_count" => results.length,
        }
      end
    end
  end

  class App
    NAV = [
      ["/", "Home"],
      ["/collections/all", "Collection"],
      ["/products/synergistic-wooden-car", "Product"],
      ["/search?q=wooden", "Search"],
      ["/cart", "Cart"],
      ["/blogs/news", "Blog"],
      ["/__bench", "Bench"],
    ].freeze

    def initialize(theme_root: File.expand_path("theme", __dir__))
      @theme_root = theme_root
      @file_system = ThemeFileSystem.new(@theme_root)
      @ctx = LiquidIL::Context.new(file_system: @file_system)
      @ctx.register_filter(ShopifyFilters, pure: true)
    end

    def call(env)
      req = Rack::Request.new(env)

      return serve_asset(req.path_info) if req.path_info.start_with?("/assets/")
      return placeholder_image(req.path_info) if req.path_info.start_with?("/images/")
      return bench_page(req) if req.path_info == "/__bench"

      template_name, assigns = route(req)
      return not_found(req.path_info) unless template_name

      html = @ctx.render(template_source(template_name), assigns)
      [200, { "content-type" => "text/html; charset=utf-8" }, [layout(req.path_info, html)]]
    rescue => e
      body = <<~HTML
        <h1>LiquidIL web demo crashed</h1>
        <pre>#{Rack::Utils.escape_html(e.class.name)}: #{Rack::Utils.escape_html(e.message)}\n#{Rack::Utils.escape_html((e.backtrace || []).first(10).join("\n"))}</pre>
      HTML
      [500, { "content-type" => "text/html; charset=utf-8" }, [layout("/500", body)]]
    end

    private

    def route(req)
      case req.path_info
      when "/"
        ["index", { "shop" => Data.shop, "collections" => Data.collections }]
      when "/collections/all"
        coll = Data.collections["all"]
        ["collection", { "collection" => coll, "collections" => Data.collections }]
      when %r{\A/products/([^/]+)\z}
        handle = Regexp.last_match(1)
        product = Data.find_product(handle)
        ["product", {
          "product" => product,
          "collection" => Data.collections["all"],
          "recommendations" => { "products" => Data.related_products(product) },
        }]
      when "/search"
        ["search", { "search" => Data.search(req.params["q"]), "collections" => Data.collections }]
      when "/cart"
        ["cart", { "cart" => Data.cart }]
      when "/blogs/news"
        ["blog", { "blog" => Data.blog }]
      else
        [nil, nil]
      end
    end

    def template_source(name)
      @template_cache ||= {}
      @template_cache[name] ||= File.read(File.join(@theme_root, "templates", "#{name}.liquid"))
    end

    def layout(path, body)
      nav = NAV.map do |href, label|
        active = (href == path || (href != "/" && path.start_with?(href.split("?").first))) ? "active" : ""
        %(<a class="#{active}" href="#{href}">#{label}</a>)
      end.join

      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>LiquidIL Web Flex</title>
            <link rel="stylesheet" href="/assets/theme.css">
          </head>
          <body>
            <header class="shell-header">
              <h1>⚡ LiquidIL Theme Flex</h1>
              <p>Shopify benchmark theme templates rendered live by LiquidIL.</p>
            </header>
            <nav class="shell-nav">#{nav}</nav>
            <main class="shell-main">#{body}</main>
          </body>
        </html>
      HTML
    end

    def serve_asset(path)
      rel = path.sub(%r{\A/assets/}, "")
      file = File.expand_path(File.join("public", rel), __dir__)
      return not_found(path) unless file.start_with?(File.expand_path("public", __dir__)) && File.file?(file)

      type = case File.extname(file)
      when ".css" then "text/css"
      when ".js" then "application/javascript"
      when ".svg" then "image/svg+xml"
      else "application/octet-stream"
      end
      [200, { "content-type" => type }, [File.read(file)]]
    end

    def placeholder_image(path)
      label = File.basename(path).sub(/\..*\z/, "")[0, 24]
      svg = <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" viewBox="0 0 800 600">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#1f2a44"/>
              <stop offset="1" stop-color="#3f2d72"/>
            </linearGradient>
          </defs>
          <rect width="800" height="600" fill="url(#g)"/>
          <text x="50%" y="50%" fill="#d9e1ff" text-anchor="middle" font-size="34" font-family="Inter,Arial,sans-serif">#{Rack::Utils.escape_html(label)}</text>
        </svg>
      SVG
      [200, { "content-type" => "image/svg+xml" }, [svg]]
    end

    def bench_page(req)
      pages = [
        ["index", { "shop" => Data.shop, "collections" => Data.collections }],
        ["collection", { "collection" => Data.collections["all"], "collections" => Data.collections }],
        ["product", {
          "product" => Data.find_product("synergistic-wooden-car"),
          "collection" => Data.collections["all"],
          "recommendations" => { "products" => Data.related_products(Data.find_product("synergistic-wooden-car")) },
        }],
        ["search", { "search" => Data.search("wood"), "collections" => Data.collections }],
        ["cart", { "cart" => Data.cart }],
        ["blog", { "blog" => Data.blog }],
      ]

      iterations = (req.params["n"] || "25").to_i.clamp(1, 400)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bytes = 0
      (iterations).times do
        pages.each do |name, assigns|
          bytes += @ctx.render(template_source(name), assigns).bytesize
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      payload = {
        iterations: iterations,
        renders: iterations * pages.size,
        elapsed_ms: (elapsed * 1000).round(2),
        per_render_ms: ((elapsed * 1000) / (iterations * pages.size)).round(4),
        output_bytes: bytes,
      }

      json = JSON.pretty_generate(payload)
      body = <<~HTML
        <section class="bench">
          <h2>Benchmark endpoint</h2>
          <p>Rendered #{pages.size} benchmark theme pages repeatedly in-process.</p>
          <pre>#{Rack::Utils.escape_html(json)}</pre>
          <p><a href="/__bench?n=#{iterations + 25}">Run with n=#{iterations + 25}</a></p>
        </section>
      HTML

      [200, { "content-type" => "text/html; charset=utf-8" }, [layout(req.path_info, body)]]
    end

    def not_found(path)
      body = <<~HTML
        <h2>404</h2>
        <p>No route for <code>#{Rack::Utils.escape_html(path)}</code>.</p>
      HTML
      [404, { "content-type" => "text/html; charset=utf-8" }, [layout(path, body)]]
    end
  end
end
