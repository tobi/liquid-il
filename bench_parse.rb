# frozen_string_literal: true

# Benchmark parse performance and allocation count
# Usage: bundle exec ruby bench_parse.rb

require_relative "lib/liquid_il"

# Representative template with diverse syntax
TEMPLATE = <<~LIQUID
  <html>
  <head><title>{{ page.title | escape }}</title></head>
  <body>
    {% if user %}
      <h1>Welcome, {{ user.name | capitalize }}!</h1>
      {% for product in products limit:10 offset:2 %}
        <div class="product">
          <h2>{{ product.title | truncate: 50 }}</h2>
          <p>{{ product.description | strip_html | truncatewords: 20 }}</p>
          <span class="price">{{ product.price | money }}</span>
          {% if product.on_sale %}
            <span class="sale">{{ product.compare_at_price | money }}</span>
          {% endif %}
          {% for tag in product.tags %}
            <span class="tag">{{ tag | downcase | escape }}</span>
          {% endfor %}
        </div>
      {% else %}
        <p>No products found.</p>
      {% endfor %}
    {% elsif admin %}
      <h1>Admin Panel</h1>
      {% case user.role %}
        {% when 'super_admin' %}
          <p>Full access</p>
        {% when 'editor' %}
          <p>Edit access</p>
        {% else %}
          <p>Read only</p>
      {% endcase %}
    {% else %}
      <p>Please log in</p>
    {% endif %}
    {% assign greeting = "Hello" | append: " " | append: user.name %}
    {{ greeting }}
    {% capture nav %}
      {% for item in navigation %}
        <a href="{{ item.url }}">{{ item.title | escape }}</a>
      {% endfor %}
    {% endcapture %}
    {{ nav }}
    {% increment counter %}
    {% decrement counter %}
    {% cycle 'odd', 'even' %}
    {% unless hide_footer %}
      <footer>© {{ 'now' | date: '%Y' }}</footer>
    {% endunless %}
    {% tablerow product in products cols:3 limit:9 %}
      {{ product.title }}
    {% endtablerow %}
  </body>
  </html>
LIQUID

# Warmup
5.times { LiquidIL::Parser.new(TEMPLATE).parse }

# Measure allocations
GC.disable
before_allocs = GC.stat[:total_allocated_objects]
100.times { LiquidIL::Parser.new(TEMPLATE).parse }
after_allocs = GC.stat[:total_allocated_objects]
GC.enable

allocs_per_parse = (after_allocs - before_allocs) / 100.0

# Measure time
iterations = 10_000
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
iterations.times { LiquidIL::Parser.new(TEMPLATE).parse }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
us_per_parse = (elapsed / iterations) * 1_000_000

puts "=== Parse Benchmark ==="
puts "Template size: #{TEMPLATE.bytesize} bytes"
puts "Time: #{'%.1f' % us_per_parse} µs/parse"
puts "Allocs: #{'%.0f' % allocs_per_parse} objects/parse"
puts "RESULT_US=#{us_per_parse.round(1)}"
puts "RESULT_ALLOCS=#{allocs_per_parse.round(0)}"
