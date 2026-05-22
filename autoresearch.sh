#!/bin/bash
set -euo pipefail

# Benchmark compile and render time
# Outputs METRIC lines for autoresearch parsing

cd "$(dirname "$0")"

ruby -I lib -e '
require "liquid_il"

# Use the same complex template as a representative workload
template = <<-LIQUID
{% for product in products %}
  {% if product.available %}
    <div class="product">
      <h2>{{ product.name | upcase }}</h2>
      <p>{{ product.description }}</p>
      <span>${{ product.price | plus: 0 | round: 2 }}</span>
      {% if product.tags.size > 0 %}
        <ul>
        {% for tag in product.tags %}
          <li>{{ tag | capitalize }}</li>
        {% endfor %}
        </ul>
      {% endif %}
      {% render "badge", label: product.badge, color: "blue" %}
    </div>
  {% endif %}
{% endfor %}
LIQUID

class FS
  def read(name); "<span class=\"badge\">{{ label }}</span>"; end
end

ctx = LiquidIL::Context.new(file_system: FS.new)

# Warmup
3.times { ctx.parse(template) }

# Compile benchmark (multiple runs for stability)
RUNS = 5
compile_times = []
RUNS.times do
  n = 500
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  n.times { ctx.parse(template) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - start
  compile_times << elapsed / n
end
compile_median = compile_times.sort[compile_times.length / 2]

# Render benchmark
tpl = ctx.parse(template)
assigns = {
  "products" => [
    { "name" => "Widget", "description" => "A widget", "price" => 9.99, "available" => true, "tags" => ["sale", "new"], "badge" => "Hot" },
    { "name" => "Gadget", "description" => "A gadget", "price" => 19.99, "available" => true, "tags" => ["clearance"], "badge" => "Sale" },
    { "name" => "Gizmo", "description" => "A gizmo", "price" => 29.99, "available" => false, "tags" => [], "badge" => "New" },
  ] * 50
}
3.times { tpl.render(assigns) }

render_times = []
RUNS.times do
  n = 500
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  n.times { tpl.render(assigns) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - start
  render_times << elapsed / n
end
render_median = render_times.sort[render_times.length / 2]

puts "METRIC compile_µs=#{compile_median}"
puts "METRIC render_µs=#{render_median}"

# Verify correctness
expected_len = tpl.render(assigns).bytesize
if expected_len < 1000
  puts "ERROR: Render output too short (#{expected_len} bytes), possible correctness issue"
  exit 1
end
'
