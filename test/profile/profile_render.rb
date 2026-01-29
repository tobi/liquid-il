# frozen_string_literal: true

# Profile script focused on render-time performance of optimized+compiled templates
#
# Usage:
#   ruby test/profile/profile_render.rb [benchmark_name] [--backend=vm|statemachine|structured]
#
# Examples:
#   ruby test/profile/profile_render.rb bench_data_table --backend=structured
#   ruby test/profile/profile_render.rb --backend=vm

require "liquid"
require_relative "../../lib/liquid_il"
require "yaml"
require "json"
require "stackprof"

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

# Parse arguments
benchmark_name = nil
backend = "statemachine" # default

ARGV.each do |arg|
  if arg.start_with?("--backend=")
    backend = arg.split("=", 2)[1]
  elsif !arg.start_with?("-")
    benchmark_name = arg
  end
end

benchmark_name ||= "bench_ecommerce_product_page"

unless %w[vm statemachine structured].include?(backend)
  puts "Unknown backend: #{backend}"
  puts "Available: vm, statemachine, structured"
  exit 1
end

# Try partials.yml first, then check if it's a built-in template
specs = YAML.load_file("benchmarks/partials.yml")["specs"]
spec = specs.find { |s| s["name"] == benchmark_name }

# Built-in templates for official benchmarks
BUILTIN_TEMPLATES = {
  "bench_data_table" => {
    "name" => "bench_data_table",
    "template" => <<~LIQUID,
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
    "environment" => {
      "headers" => ["name", "email", "role", "status"],
      "rows" => [
        {"name" => "Alice", "email" => "alice@example.com", "role" => "Admin", "status" => "Active"},
        {"name" => "Bob", "email" => "bob@example.com", "role" => "User", "status" => "Active"},
        {"name" => "Charlie", "email" => "charlie@example.com", "role" => "User", "status" => "Inactive"},
        {"name" => "Diana", "email" => "diana@example.com", "role" => "Editor", "status" => "Active"},
        {"name" => "Eve", "email" => "eve@example.com", "role" => "User", "status" => "Pending"}
      ]
    },
    "filesystem" => {}
  }
}

spec ||= BUILTIN_TEMPLATES[benchmark_name]

unless spec
  puts "Unknown benchmark: #{benchmark_name}"
  puts "Available: #{specs.map { |s| s['name'] }.join(', ')}, #{BUILTIN_TEMPLATES.keys.join(', ')}"
  exit 1
end

name = spec["name"]
template_source = spec["template"]
env = spec["environment"]
env = env.is_a?(String) ? JSON.parse(env.gsub("=>", ":")) : env
fs = spec["filesystem"] || {}

puts "Profiling: #{name} (backend: #{backend})"
puts "=" * 60

# Create optimized context
context = LiquidIL::Context.new(file_system: BenchFS.new(fs))
optimized_context = LiquidIL::Optimizer.optimize(context)

# Parse and compile (this is compile-time, not measured)
template = optimized_context.parse(template_source)

compiled_template = case backend
when "vm"
  template # VM uses the template directly
when "statemachine"
  LiquidIL::Compiler::Ruby.compile(template)
when "structured"
  LiquidIL::Compiler::Structured.compile(template)
end


# Warmup
puts "Warming up..."
100.times { compiled_template.render(env) }

# Profile render only
iterations = 5000
puts "Profiling #{iterations} render iterations..."

Dir.mkdir("tmp") unless Dir.exist?("tmp")

profile_file = "tmp/render_#{backend}_profile.dump"

StackProf.run(mode: :wall, out: profile_file, raw: true, interval: 100) do
  iterations.times { compiled_template.render(env) }
end

puts "Profile saved to #{profile_file}"
puts
puts "View with:"
puts "  bundle exec stackprof #{profile_file} --text"
puts "  bundle exec stackprof #{profile_file} --text --limit 30"
puts "  bundle exec stackprof #{profile_file} --method 'METHOD_NAME'"
puts
puts "Flamegraph:"
puts "  bundle exec stackprof #{profile_file} --d3-flamegraph > tmp/render_#{backend}_flamegraph.html"
