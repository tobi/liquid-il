# frozen_string_literal: true

require "minitest/autorun"
require "liquid"
require_relative "../lib/liquid_il"

# Minimal repro for collection template bug:
# include inside paginate+for over hash products.
class PaginateIncludeReproTest < Minitest::Test
  TEMPLATE = <<~LIQUID
    {% assign _products = collection.products %}
    {% paginate _products by 12 %}
      {% for product in _products %}
        {% include 'product-card' %}
      {% endfor %}
    {% endpaginate %}
  LIQUID

  SNIPPET = "{{ product.url }}\n"

  class FS
    def initialize(map)
      @map = map
    end

    def read_template_file(name, _context = nil)
      @map[name.to_s] || @map["#{name}.liquid"]
    end
  end

  # Shopify-like paginate tag from liquid-spec reference adapter.
  class PaginateTag < Liquid::Block
    Syntax = /(#{Liquid::QuotedFragment})\s+by\s+(\d+)/

    def initialize(tag_name, markup, options)
      super
      raise Liquid::SyntaxError, "Valid syntax: paginate [collection] by [number]" unless markup =~ Syntax

      @collection_name = Regexp.last_match(1)
      @page_size = Regexp.last_match(2).to_i
    end

    def render_to_output_buffer(context, output)
      collection = context[@collection_name]
      return super unless collection.respond_to?(:size)

      page_size = @page_size
      current_page = [(context["current_page"] || 1).to_i, 1].max
      total_items = collection.size
      total_pages = page_size > 0 ? (total_items.to_f / page_size).ceil : 1
      total_pages = 1 if total_pages == 0 && total_items > 0

      paginate = {
        "page_size" => page_size,
        "current_page" => current_page,
        "current_offset" => (current_page - 1) * page_size,
        "items" => total_items,
        "pages" => total_pages,
        "parts" => [],
      }

      offset = (current_page - 1) * page_size
      sliced = collection.drop(offset).take(page_size)

      context.stack do
        context[@collection_name] = sliced
        context["paginate"] = paginate
        super
      end
    end
  end

  def assigns
    {
      "collection" => {
        "products" => [
          { "url" => "/a" },
          { "url" => "/b" },
        ],
      },
    }
  end

  def test_reference_liquid_ruby_behavior
    base = Liquid::Environment.build
    env = Liquid::Environment.build(tags: base.tags.merge("paginate" => PaginateTag))

    t = Liquid::Template.parse(TEMPLATE, environment: env)
    out = t.render!(
      assigns,
      registers: { file_system: FS.new("product-card" => SNIPPET) },
      strict_variables: false,
      strict_filters: false,
    )

    assert_equal "/a\n/b\n", out.gsub(/^\s+/, "")
  end

  def test_liquid_il_current_behavior_repro
    ctx = LiquidIL::Context.new(file_system: FS.new("product-card" => SNIPPET))
    out = ctx.render(TEMPLATE, assigns)

    assert_includes out, "Liquid error (product-card line 1): no implicit conversion of String into Integer"
  end
end
