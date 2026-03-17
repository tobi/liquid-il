# frozen_string_literal: true
# YJIT deep analysis on real Shopify theme product page
# Usage: ~/.rubies/ruby-4.0.2-yjit-dev/bin/ruby --yjit -Ilib auto/yjit-shopify-analysis.rb

require "yaml"
require "liquid_il"

# Register shopify filters inline (extracted from spec/liquid_il_shopify.rb)
LiquidIL::Filters.singleton_class.class_eval do
  def asset_url(input) = "/files/1/[shop_id]/[shop_id]/assets/#{input}"
  def product_img_url(input, size = nil)
    return "" unless input
    url = input.is_a?(String) ? input : input.to_s
    size && size != "original" ? "/products/#{url.sub(/\.(\w+)\z/, "_#{size}.\\1")}" : "/products/#{url}"
  end
  def img_url(input, size = nil)
    return "" unless input
    url = input.is_a?(String) ? input : input.to_s
    size ? "/assets/#{url.split("/").last.sub(/\.(\w+)\z/, "_#{size}.\\1")}" : "/assets/#{url.split("/").last}"
  end
  def money(input)
    return "$0.00" unless input
    cents = input.is_a?(String) ? input.to_f : input.to_f
    "$#{'%.2f' % (cents / 100.0)}"
  end
  def handle(input) = input.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  def json(input)
    require "json" unless defined?(JSON)
    JSON.generate(input)
  end
  def handleize(input) = handle(input)
  def stylesheet_tag(url) = "<link href=\"#{url}\" rel=\"stylesheet\" type=\"text/css\" media=\"all\">"
  def script_tag(url) = "<script src=\"#{url}\" type=\"text/javascript\"></script>"
end
LiquidIL::Filters.instance_variable_set(:@valid_filter_methods, nil)

SPEC_DIR = File.join(`bundle info liquid-spec --path 2>/dev/null`.strip, "specs", "benchmarks")

# Load theme database
db = YAML.load_file(File.join(SPEC_DIR, "_data", "theme_database.yml"), aliases: true)

# Load the theme_product spec
spec_data = YAML.load_file(File.join(SPEC_DIR, "theme_product.yml"), aliases: true)
spec = spec_data["specs"][0]
template_source = spec["template"]
environment = spec["environment"]

# Merge in the collections from the database for "You Might Also Like" section
environment["collections"] = db["collections"] if db["collections"]

# Set up filesystem for partials
filesystem = spec["filesystem"] || {}

def count_allocs
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
end

# Create a file system that resolves partials
class MemoryFS
  def initialize(files)
    @files = files
  end

  def read_template_file(name)
    key = @files.keys.find { |k| k.start_with?(name) } || name
    @files[key] || raise("Template not found: #{name}")
  end
end

fs = MemoryFS.new(filesystem)
ctx = LiquidIL::Context.new(file_system: fs)

# Compile
puts "Compiling theme_product template..."
compiled = LiquidIL::Compiler::Structured.compile(template_source, context: ctx)

puts "\n#{'=' * 70}"
puts "YJIT SHOPIFY ANALYSIS — theme_product page"
puts "#{'=' * 70}"

# Generated code size
puts "\n## Generated Ruby Source"
puts "-" * 50
src = compiled.compiled_source
lines = src.count("\n")
bytes = src.bytesize
puts "  Total: #{bytes} bytes, #{lines} lines"
# Show code structure summary
method_calls = src.scan(/_H\.\w+|_U\.\w+|_S\.\w+|LiquidIL::\w+/).tally.sort_by { |_, v| -v }
puts "\n  Top method calls in generated code:"
method_calls.first(15).each { |call, count| puts "    #{count}x #{call}" }

# Warm up
puts "\n## Warming up (200 iterations)..."
200.times { compiled.render(environment) }

# Allocation analysis
puts "\n## Render Allocation Counts"
puts "-" * 50
# Run twice — first warms inline caches
count_allocs { compiled.render(environment) }
allocs = count_allocs { compiled.render(environment) }
puts "  Total render allocs: #{allocs}"

# Parse allocation analysis
puts "\n## Parse Allocation Counts"
puts "-" * 50
3.times { LiquidIL::Compiler::Structured.compile(template_source, context: ctx) }
parse_allocs = count_allocs { LiquidIL::Compiler::Structured.compile(template_source, context: ctx) }
puts "  Total parse allocs: #{parse_allocs}"

# Detailed allocation tracing
puts "\n## Allocation Sources (render)"
puts "-" * 50
require "objspace"
GC.start; GC.start; GC.start
GC.disable
ObjectSpace.trace_object_allocations_start
compiled.render(environment)
ObjectSpace.trace_object_allocations_stop
GC.enable

allocs_by_source = Hash.new(0)
allocs_by_class = Hash.new(0)
ObjectSpace.each_object do |obj|
  src = ObjectSpace.allocation_sourcefile(obj)
  line = ObjectSpace.allocation_sourceline(obj)
  gen = ObjectSpace.allocation_generation(obj)
  if src && gen
    short = src.sub(%r{.*/liquid_il/}, "").sub(%r{.*/liquid-spec[^/]*/}, "liquid-spec/")
    allocs_by_source["#{short}:#{line}"] += 1
    allocs_by_class[obj.class.name] += 1
  end
end

puts "  By source location (top 25):"
allocs_by_source.sort_by { |_, v| -v }.first(25).each { |src, count| puts "    #{count} allocs at #{src}" }
puts "\n  By object class:"
allocs_by_class.sort_by { |_, v| -v }.first(15).each { |cls, count| puts "    #{count}x #{cls}" }

# YJIT analysis
if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  puts "\n## YJIT Stats"
  puts "-" * 50
  stats = RubyVM::YJIT.runtime_stats
  %i[inline_code_size outlined_code_size compiled_iseq_count compiled_block_count
     invalidation_count vm_insns_count yjit_alloc_size].each do |k|
    puts "  %-30s %s" % [k, stats[k]] if stats[k]
  end

  # Disasm the compiled proc itself
  puts "\n## YJIT Disasm — Compiled Template Proc"
  puts "=" * 70
  # The compiled proc is stored as @compiled_proc
  proc_obj = compiled.instance_variable_get(:@compiled_proc)
  if proc_obj
    disasm = RubyVM::YJIT.disasm(proc_obj)
    blocks = disasm.scan(/== BLOCK \d+/).count
    total_line = disasm[/TOTAL INLINE CODE SIZE: (\d+) bytes/, 1]
    num_blocks_line = disasm[/NUM BLOCK VERSIONS: (\d+)/, 1]
    puts "  JIT blocks: #{blocks}, Inline code: #{total_line || '?'} bytes"

    # Show bytecode summary
    bytecodes = disasm.lines.select { |l| l.match?(/^\d{4} /) }
    puts "  Bytecode instructions: #{bytecodes.count}"

    # Show what's NOT being JIT'd (side exits / deopt points)
    side_exits = disasm.scan(/b\.\w+\s+#0x[0-9a-f]+/).count
    puts "  Branch instructions (potential side exits): #{side_exits}"

    # Machine code block sizes
    machine_blocks = disasm.scan(/== BLOCK (\d+)\/(\d+), ISEQ RANGE \[(\d+),(\d+)\), (\d+) bytes/)
    if machine_blocks.any?
      total_mc_bytes = machine_blocks.sum { |b| b[4].to_i }
      puts "  Total machine code: #{total_mc_bytes} bytes across #{machine_blocks.length} blocks"
      large_blocks = machine_blocks.select { |b| b[4].to_i > 200 }.sort_by { |b| -b[4].to_i }
      if large_blocks.any?
        puts "  Largest machine code blocks:"
        large_blocks.first(10).each { |b| puts "    Block #{b[0]}/#{b[1]}: ISEQ [#{b[2]},#{b[3]}) = #{b[4]} bytes" }
      end
    end
  end

  # Disasm hot helper methods
  puts "\n## YJIT Disasm — Hot Helper Methods"
  puts "=" * 70

  helpers = {
    "StructuredHelpers.lookup_prop" => LiquidIL::StructuredHelpers.method(:lookup_prop),
    "StructuredHelpers.lookup_prop_fast" => LiquidIL::StructuredHelpers.method(:lookup_prop_fast),
    "StructuredHelpers.output_append" => LiquidIL::StructuredHelpers.method(:output_append),
    "StructuredHelpers.oa" => (LiquidIL::StructuredHelpers.method(:oa) rescue nil),
    "StructuredHelpers.lookup" => LiquidIL::StructuredHelpers.method(:lookup),
    "Scope#lookup" => LiquidIL::Scope.new({}).method(:lookup),
    "Filters.apply" => (LiquidIL::Filters.method(:apply) rescue nil),
  }.compact

  helpers.each do |label, meth|
    disasm = RubyVM::YJIT.disasm(meth)
    blocks = disasm.scan(/== BLOCK \d+/).count
    total_line = disasm[/TOTAL INLINE CODE SIZE: (\d+) bytes/, 1]
    machine_blocks = disasm.scan(/== BLOCK (\d+)\/(\d+), ISEQ RANGE \[(\d+),(\d+)\), (\d+) bytes/)
    total_mc = machine_blocks.sum { |b| b[4].to_i }

    jit_status = blocks > 0 ? "✅ JIT'd" : "❌ NOT JIT'd"
    puts "  %-45s %s  %3d blocks, %5d bytes MC" % [label, jit_status, blocks, total_mc]
  end

  # Full disasm of the compiled proc for deep analysis
  puts "\n## Full Bytecode — Compiled Template Proc (first 100 instructions)"
  puts "-" * 70
  if proc_obj
    disasm = RubyVM::YJIT.disasm(proc_obj)
    bytecodes = disasm.lines.select { |l| l.match?(/^\d{4} /) || l.match?(/^== disasm/) || l.match?(/^local table/) }
    puts bytecodes.first(100).join
    puts "  ... (#{bytecodes.length} total bytecode lines)" if bytecodes.length > 100
  end
else
  puts "\n⚠️  YJIT not in dev mode. Run with:"
  puts "  ~/.rubies/ruby-4.0.2-yjit-dev/bin/ruby --yjit -Ilib auto/yjit-shopify-analysis.rb"
end
