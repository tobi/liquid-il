# frozen_string_literal: true

# Profile the VM interpreter render path with optimized IL
# Goal: find hot paths in the interpreter that can be optimized

require "liquid"
require_relative "lib/liquid_il"
require "stackprof"

# Use the product listing benchmark template (realistic e-commerce workload)
SOURCE = <<~LIQUID
  <div class="products">
    {% for product in products %}
      <div class="product">
        <h2>{{ product.title }}</h2>
        <p class="price">${{ product.price }}</p>
        {% if product.on_sale %}
          <span class="badge">Sale!</span>
        {% endif %}
        <p>{{ product.description }}</p>
        {% for variant in product.variants %}
          <span class="variant">{{ variant.name }}: {{ variant.value }}</span>
        {% endfor %}
      </div>
    {% endfor %}
  </div>
LIQUID

# Realistic data
ASSIGNS = {
  "products" => 10.times.map do |i|
    {
      "title" => "Product #{i + 1}",
      "price" => (19.99 + i * 10).round(2),
      "on_sale" => i.even?,
      "description" => "This is a great product with many features. It's perfect for your needs.",
      "variants" => [
        { "name" => "Size", "value" => %w[S M L XL][i % 4] },
        { "name" => "Color", "value" => %w[Red Blue Green Black][i % 4] }
      ]
    }
  end
}.freeze

ITERATIONS = 1000

puts "Template: #{SOURCE.lines.count} lines"
puts "Data: #{ASSIGNS["products"].size} products"
puts "Iterations: #{ITERATIONS}"
puts

# Compile with optimization (but use VM, not Ruby compiler)
context = LiquidIL::Context.new
optimized_context = LiquidIL::Optimizer.optimize(context)
template = optimized_context.parse(SOURCE)

# Warmup
puts "Warming up..."
50.times { template.render(ASSIGNS) }

# Verify output
output = template.render(ASSIGNS)
puts "Output size: #{output.bytesize} bytes"
puts

# Profile render
puts "Profiling #{ITERATIONS} renders..."
Dir.mkdir("tmp") unless Dir.exist?("tmp")

StackProf.run(mode: :wall, out: "tmp/vm_render_profile.dump", raw: true, interval: 100) do
  ITERATIONS.times { template.render(ASSIGNS) }
end

puts "Profile saved to tmp/vm_render_profile.dump"
puts

# Also do CPU mode
StackProf.run(mode: :cpu, out: "tmp/vm_render_cpu.dump", raw: true, interval: 100) do
  ITERATIONS.times { template.render(ASSIGNS) }
end

puts "CPU profile saved to tmp/vm_render_cpu.dump"
puts

# Print inline summary
puts "=" * 70
puts "WALL TIME PROFILE (top 30)"
puts "=" * 70
system("bundle exec stackprof tmp/vm_render_profile.dump --text --limit 30")

puts
puts "=" * 70
puts "CPU PROFILE (top 30)"
puts "=" * 70
system("bundle exec stackprof tmp/vm_render_cpu.dump --text --limit 30")

puts
puts "=" * 70
puts "METHOD DETAILS - VM#execute"
puts "=" * 70
system("bundle exec stackprof tmp/vm_render_profile.dump --method 'LiquidIL::VM#execute'")
