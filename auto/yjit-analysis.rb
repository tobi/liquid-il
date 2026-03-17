# frozen_string_literal: true
# YJIT analysis script — run with the yjit-dev ruby to get disasm
# Usage: ~/.rubies/ruby-4.0.2-yjit-dev/bin/ruby --yjit -Ilib auto/yjit-analysis.rb

require "liquid_il"

# Templates from the benchmark suite
TEMPLATES = {
  "simple_variable" => '{{ title }}',
  "filter_chain" => '{{ title | upcase | truncate: 10 }}',
  "for_loop" => '{% for i in (1..10) %}{{ i }}{% endfor %}',
  "nested_loop" => '{% for i in (1..5) %}{% for j in (1..5) %}{{ i }}-{{ j }} {% endfor %}{% endfor %}',
  "if_else" => '{% if show %}yes{% else %}no{% endif %}',
  "assign_and_output" => '{% assign x = "hello" | upcase %}{{ x }}',
}

def count_allocs
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
end

# Compile all templates and warm up
compiled = {}
TEMPLATES.each do |name, source|
  result = LiquidIL::Compiler::Structured.compile(source)
  compiled[name] = result
end

# Warm up all templates
assigns = { "title" => "Hello World", "show" => true }
200.times do
  compiled.each do |_name, result|
    result.render(assigns)
  end
end

puts "=" * 70
puts "YJIT ANALYSIS — LiquidIL Render Hot Paths"
puts "=" * 70

# Code size analysis
puts "\n## Generated Code Size"
puts "-" * 50
compiled.each do |name, result|
  src = result.source
  lines = src.count("\n")
  bytes = src.bytesize
  puts "  %-25s %5d bytes, %3d lines" % [name, bytes, lines]
end

# Allocation analysis
puts "\n## Allocation Counts (per render)"
puts "-" * 50
compiled.each do |name, result|
  assigns = { "title" => "Hello World", "show" => true }
  # Warm
  5.times { result.render(assigns) }
  # Measure
  allocs = count_allocs { result.render(assigns) }
  puts "  %-25s %4d allocs" % [name, allocs]
end

# Parse allocation analysis
puts "\n## Parse Allocation Counts"
puts "-" * 50
TEMPLATES.each do |name, source|
  # Warm
  3.times { LiquidIL::Compiler::Structured.compile(source) }
  allocs = count_allocs { LiquidIL::Compiler::Structured.compile(source) }
  puts "  %-25s %4d allocs" % [name, allocs]
end

# YJIT disasm of hot render methods
if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  puts "\n## YJIT Disasm — Render Methods"
  puts "=" * 70

  # Disasm the render method of each compiled template
  compiled.each do |name, result|
    puts "\n### #{name}"
    puts "-" * 50
    disasm = RubyVM::YJIT.disasm(result.method(:render))
    
    # Count blocks and total code size
    blocks = disasm.scan(/== BLOCK \d+/).count
    total_line = disasm[/TOTAL INLINE CODE SIZE: (\d+) bytes/, 1]
    
    puts "  Blocks: #{blocks}, Inline code: #{total_line || '?'} bytes"
    
    # Show just the bytecode (not machine code) for readability
    bytecode_lines = disasm.lines.select { |l| 
      l.match?(/^\d{4} /) || l.match?(/^== disasm:/) || l.match?(/^local table/)
    }
    puts bytecode_lines.first(30).join if bytecode_lines.any?
    puts "  ..." if bytecode_lines.length > 30
  end

  # YJIT stats
  puts "\n## YJIT Runtime Stats"
  puts "-" * 50
  stats = RubyVM::YJIT.runtime_stats
  %i[inline_code_size outlined_code_size compiled_iseq_count compiled_block_count
     invalidation_count vm_insns_count yjit_alloc_size].each do |k|
    puts "  %-30s %s" % [k, stats[k]] if stats[k]
  end

  # Disasm key helper methods
  puts "\n## YJIT Disasm — Hot Helper Methods"
  puts "=" * 70

  helpers_to_check = [
    ["StructuredHelpers.lookup_prop", LiquidIL::StructuredHelpers.method(:lookup_prop)],
    ["StructuredHelpers.lookup_prop_fast", LiquidIL::StructuredHelpers.method(:lookup_prop_fast)],
    ["StructuredHelpers.output_append", LiquidIL::StructuredHelpers.method(:output_append)],
  ]

  # Also check Scope#lookup if it exists
  scope = LiquidIL::Scope.new({}) rescue nil
  if scope
    helpers_to_check << ["Scope#lookup", scope.method(:lookup)]
  end

  helpers_to_check.each do |label, meth|
    puts "\n### #{label}"
    puts "-" * 50
    disasm = RubyVM::YJIT.disasm(meth)
    blocks = disasm.scan(/== BLOCK \d+/).count
    total_line = disasm[/TOTAL INLINE CODE SIZE: (\d+) bytes/, 1]
    puts "  Blocks: #{blocks}, Inline code: #{total_line || '?'} bytes"
    
    # Show bytecode portion
    bytecode_lines = disasm.lines.select { |l| l.match?(/^\d{4} /) }
    puts bytecode_lines.first(20).join if bytecode_lines.any?
    
    # Show machine code blocks summary
    machine_blocks = disasm.scan(/== BLOCK (\d+)\/(\d+), ISEQ RANGE \[(\d+),(\d+)\), (\d+) bytes/)
    if machine_blocks.any?
      puts "  Machine code blocks:"
      machine_blocks.each do |b|
        puts "    Block #{b[0]}/#{b[1]}: ISEQ [#{b[2]},#{b[3]}) = #{b[4]} bytes"
      end
    end
  end
else
  puts "\n⚠️  YJIT not in dev mode — run with:"
  puts "  ~/.rubies/ruby-4.0.2-yjit-dev/bin/ruby --yjit -Ilib auto/yjit-analysis.rb"
end
