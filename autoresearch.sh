#!/bin/bash
set -euo pipefail

# Benchmark compile + render time with cold/warm render and allocation tracking
# Outputs METRIC lines for autoresearch parsing

cd "$(dirname "$0")"

ruby -I lib -e '
begin; RubyVM::YJIT.enable; rescue; end
require "liquid_il"
require "objspace"

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

# Warmup: compile the template a few times so JIT/codegen cache warms
3.times { ctx.parse(template) }

assigns = {
  "products" => [
    { "name" => "Widget", "description" => "A widget", "price" => 9.99, "available" => true, "tags" => ["sale", "new"], "badge" => "Hot" },
    { "name" => "Gadget", "description" => "A gadget", "price" => 19.99, "available" => true, "tags" => ["clearance"], "badge" => "Sale" },
    { "name" => "Gizmo", "description" => "A gizmo", "price" => 29.99, "available" => false, "tags" => [], "badge" => "New" },
  ] * 50
}

RUNS = 5

# --- Compile benchmark (includes allocations) ---
compile_times = []
compile_allocs = []
RUNS.times do
  GC.start
  # Measure objects allocated during compile
  before = GC.stat(:total_allocated_objects) || 0
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  n = 500
  n.times { ctx.parse(template) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - start
  after = GC.stat(:total_allocated_objects) || 0
  compile_times << elapsed / n
  compile_allocs << ((after - before) / n)
end
compile_median = compile_times.sort[compile_times.length / 2]
compile_allocs_median = compile_allocs.sort[compile_allocs.length / 2]

# --- Render cold benchmark (first render immediately after parse, no warmup) ---
render_cold_times = []
render_cold_allocs = []
RUNS.times do
  GC.start
  before = GC.stat(:total_allocated_objects) || 0
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  n = 500
  n.times do
    tpl = ctx.parse(template)
    tpl.render(assigns)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - start
  after = GC.stat(:total_allocated_objects) || 0
  render_cold_times << elapsed / n
  render_cold_allocs << ((after - before) / n)
end
render_cold_median = render_cold_times.sort[render_cold_times.length / 2]
render_cold_allocs_median = render_cold_allocs.sort[render_cold_allocs.length / 2]

# --- Render warm benchmark (warm first, then measure) ---
tpl = ctx.parse(template)
100.times { tpl.render(assigns) }  # warmup (includes YJIT compilation)

render_warm_times = []
render_warm_allocs = []
RUNS.times do
  GC.start
  before = GC.stat(:total_allocated_objects) || 0
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  n = 500
  n.times { tpl.render(assigns) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - start
  after = GC.stat(:total_allocated_objects) || 0
  render_warm_times << elapsed / n
  render_warm_allocs << ((after - before) / n)
end
render_warm_median = render_warm_times.sort[render_warm_times.length / 2]
render_warm_allocs_median = render_warm_allocs.sort[render_warm_allocs.length / 2]

total_median = compile_median + render_warm_median

puts "METRIC total_µs=#{(total_median + 0.5).to_i}"
puts "METRIC compile_µs=#{(compile_median + 0.5).to_i}"
puts "METRIC render_warm_µs=#{(render_warm_median + 0.5).to_i}"
puts "METRIC render_cold_µs=#{(render_cold_median + 0.5).to_i}"
puts "METRIC compile_allocs=#{compile_allocs_median}"
puts "METRIC render_warm_allocs=#{render_warm_allocs_median}"
puts "METRIC total_allocs=#{compile_allocs_median + render_warm_allocs_median}"

# Verify correctness
expected_len = tpl.render(assigns).bytesize
if expected_len < 1000
  puts "ERROR: Render output too short (#{expected_len} bytes), possible correctness issue"
  exit 1
end
'
