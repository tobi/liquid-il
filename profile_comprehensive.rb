# frozen_string_literal: true

# Comprehensive profiling script for LiquidIL optimization analysis
# Profiles: parsing, IL generation, Ruby compilation, and rendering

require "liquid"
require_relative "lib/liquid_il"
require "yaml"
require "json"
require "stackprof"
require "memory_profiler"

Dir.mkdir("tmp") unless Dir.exist?("tmp")

class BenchFS
  def initialize(files)
    @files = files
  end

  def read(name)
    @files[name] || ""
  end

  def read_template_file(name)
    @files[name] || ""
  end
end

# Test templates of varying complexity
TEMPLATES = {
  simple_output: {
    source: "Hello {{ name }}!",
    env: { "name" => "World" }
  },
  filter_chain: {
    source: "{{ message | upcase | append: '!' | prepend: '>>> ' }}",
    env: { "message" => "hello world" }
  },
  simple_loop: {
    source: "{% for i in items %}{{ i }} {% endfor %}",
    env: { "items" => (1..10).to_a }
  },
  nested_loops: {
    source: <<~LIQUID,
      {% for row in rows %}
        {% for col in cols %}
          {{ row }}-{{ col }}
        {% endfor %}
      {% endfor %}
    LIQUID
    env: { "rows" => (1..5).to_a, "cols" => %w[a b c d e] }
  },
  conditionals: {
    source: <<~LIQUID,
      {% if user.admin %}
        Admin: {{ user.name }}
      {% elsif user.moderator %}
        Mod: {{ user.name }}
      {% else %}
        User: {{ user.name }}
      {% endif %}
    LIQUID
    env: { "user" => { "name" => "Alice", "admin" => false, "moderator" => true } }
  },
  complex_ecommerce: {
    source: <<~LIQUID,
      <div class="product">
        <h1>{{ product.title | escape }}</h1>
        <p class="price">{{ product.price | money }}</p>
        {% if product.on_sale %}
          <span class="sale-badge">SALE!</span>
        {% endif %}
        <ul class="variants">
        {% for variant in product.variants %}
          <li>
            {{ variant.title }} - {{ variant.price | money }}
            {% if variant.available %}
              <button>Add to cart</button>
            {% else %}
              <span>Sold out</span>
            {% endif %}
          </li>
        {% endfor %}
        </ul>
        {% if product.description != blank %}
          <div class="description">
            {{ product.description }}
          </div>
        {% endif %}
      </div>
    LIQUID
    env: {
      "product" => {
        "title" => "Cool T-Shirt",
        "price" => 2999,
        "on_sale" => true,
        "description" => "A very cool t-shirt made from 100% cotton.",
        "variants" => [
          { "title" => "Small", "price" => 2999, "available" => true },
          { "title" => "Medium", "price" => 2999, "available" => true },
          { "title" => "Large", "price" => 2999, "available" => false },
          { "title" => "XL", "price" => 3499, "available" => true }
        ]
      }
    }
  },
  data_table: {
    source: <<~LIQUID,
      <table>
        <thead>
          <tr>
          {% for header in headers %}
            <th>{{ header | capitalize }}</th>
          {% endfor %}
          </tr>
        </thead>
        <tbody>
        {% for row in rows %}
          <tr>
          {% for header in headers %}
            <td>{{ row[header] }}</td>
          {% endfor %}
          </tr>
        {% endfor %}
        </tbody>
      </table>
    LIQUID
    env: {
      "headers" => %w[name email role status],
      "rows" => [
        { "name" => "Alice", "email" => "alice@example.com", "role" => "Admin", "status" => "Active" },
        { "name" => "Bob", "email" => "bob@example.com", "role" => "User", "status" => "Active" },
        { "name" => "Charlie", "email" => "charlie@example.com", "role" => "User", "status" => "Inactive" },
        { "name" => "Diana", "email" => "diana@example.com", "role" => "Editor", "status" => "Active" },
        { "name" => "Eve", "email" => "eve@example.com", "role" => "User", "status" => "Pending" }
      ]
    }
  }
}

def measure_allocations
  x = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - x
end

def time_it(label, iterations: 1)
  GC.start
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { yield }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "#{label}: #{(elapsed * 1000 / iterations).round(3)}ms per iteration (#{iterations} iterations)"
  elapsed
end

puts "=" * 70
puts "LIQUIDIL COMPREHENSIVE PROFILER"
puts "=" * 70
puts

# 1. COMPILE-TIME PROFILING
puts "=" * 70
puts "1. COMPILE-TIME PROFILING"
puts "=" * 70
puts

compile_iterations = 100

TEMPLATES.each do |name, data|
  puts "--- #{name} ---"
  source = data[:source]

  context = LiquidIL::Context.new
  optimized_context = LiquidIL::Optimizer.optimize(context)

  # Warmup
  10.times do
    tpl = optimized_context.parse(source)
    LiquidIL::Compiler::Ruby.compile(tpl)
  end

  # Time parsing
  allocs = measure_allocations do
    time_it("  Parse", iterations: compile_iterations) do
      optimized_context.parse(source)
    end
  end
  puts "  Parse allocations: #{allocs / compile_iterations} per call"

  # Time Ruby compilation
  template = optimized_context.parse(source)
  allocs = measure_allocations do
    time_it("  Ruby compile", iterations: compile_iterations) do
      LiquidIL::Compiler::Ruby.compile(template)
    end
  end
  puts "  Ruby compile allocations: #{allocs / compile_iterations} per call"
  puts
end

# 2. RENDER-TIME PROFILING
puts "=" * 70
puts "2. RENDER-TIME PROFILING"
puts "=" * 70
puts

render_iterations = 1000

TEMPLATES.each do |name, data|
  puts "--- #{name} ---"
  source = data[:source]
  env = data[:env]

  context = LiquidIL::Context.new
  optimized_context = LiquidIL::Optimizer.optimize(context)
  template = optimized_context.parse(source)
  compiled = LiquidIL::Compiler::Ruby.compile(template)

  # Warmup
  100.times { compiled.render(env) }

  # Time render
  allocs = measure_allocations do
    time_it("  Render", iterations: render_iterations) do
      compiled.render(env)
    end
  end
  puts "  Render allocations: #{allocs / render_iterations} per call"
  puts
end

# 3. DETAILED STACKPROF - Complex template compile-time
puts "=" * 70
puts "3. DETAILED STACKPROF - COMPILE TIME"
puts "=" * 70
puts

source = TEMPLATES[:complex_ecommerce][:source]
context = LiquidIL::Context.new
optimized_context = LiquidIL::Optimizer.optimize(context)

# Warmup
50.times do
  tpl = optimized_context.parse(source)
  LiquidIL::Compiler::Ruby.compile(tpl)
end

# Profile compile
StackProf.run(mode: :wall, out: "tmp/compile_profile.dump", raw: true, interval: 100) do
  500.times do
    tpl = optimized_context.parse(source)
    LiquidIL::Compiler::Ruby.compile(tpl)
  end
end
puts "Compile profile saved to tmp/compile_profile.dump"

# 4. DETAILED STACKPROF - Render time
puts
puts "=" * 70
puts "4. DETAILED STACKPROF - RENDER TIME"
puts "=" * 70
puts

template = optimized_context.parse(source)
compiled = LiquidIL::Compiler::Ruby.compile(template)
env = TEMPLATES[:complex_ecommerce][:env]

# Warmup
100.times { compiled.render(env) }

# Profile render
StackProf.run(mode: :wall, out: "tmp/render_profile.dump", raw: true, interval: 100) do
  5000.times { compiled.render(env) }
end
puts "Render profile saved to tmp/render_profile.dump"

# 5. MEMORY PROFILING
puts
puts "=" * 70
puts "5. MEMORY PROFILING - COMPILE TIME"
puts "=" * 70
puts

report = MemoryProfiler.report do
  50.times do
    tpl = optimized_context.parse(source)
    LiquidIL::Compiler::Ruby.compile(tpl)
  end
end

puts "Top 20 allocations by gem:"
report.pretty_print(to_file: "tmp/compile_memory.txt", detailed_report: true)
puts "Full memory report saved to tmp/compile_memory.txt"
puts

# Print summary
puts "Compile memory summary:"
puts "  Total allocated: #{report.total_allocated} bytes"
puts "  Total retained: #{report.total_retained} bytes"
puts "  Total allocated objects: #{report.total_allocated_memsize}"

puts
puts "=" * 70
puts "6. MEMORY PROFILING - RENDER TIME"
puts "=" * 70
puts

report = MemoryProfiler.report do
  1000.times { compiled.render(env) }
end

puts "Render memory summary:"
puts "  Total allocated: #{report.total_allocated} bytes"
puts "  Total retained: #{report.total_retained} bytes"
puts "  Total allocated objects: #{report.total_allocated_memsize}"

report.pretty_print(to_file: "tmp/render_memory.txt", detailed_report: true)
puts "Full memory report saved to tmp/render_memory.txt"

# 6. OUTPUT GENERATED RUBY CODE
puts
puts "=" * 70
puts "7. GENERATED RUBY CODE (complex_ecommerce)"
puts "=" * 70
puts

# Get the generated Ruby source
if compiled.respond_to?(:source)
  File.write("tmp/generated_ruby.rb", compiled.source)
  puts "Generated Ruby saved to tmp/generated_ruby.rb"
  puts
  puts compiled.source
elsif compiled.instance_variable_defined?(:@source)
  src = compiled.instance_variable_get(:@source)
  File.write("tmp/generated_ruby.rb", src)
  puts "Generated Ruby saved to tmp/generated_ruby.rb"
  puts
  puts src
else
  puts "Cannot extract generated Ruby source - need to check compiler API"
end

puts
puts "=" * 70
puts "PROFILING COMPLETE"
puts "=" * 70
puts
puts "View profiles with:"
puts "  bundle exec stackprof tmp/compile_profile.dump --text --limit 30"
puts "  bundle exec stackprof tmp/render_profile.dump --text --limit 30"
puts "  bundle exec stackprof tmp/compile_profile.dump --d3-flamegraph > tmp/compile_flamegraph.html"
puts "  bundle exec stackprof tmp/render_profile.dump --d3-flamegraph > tmp/render_flamegraph.html"
