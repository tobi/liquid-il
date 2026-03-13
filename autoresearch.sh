#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")"

# Quick syntax check on key files
for f in lib/liquid_il/structured_compiler.rb lib/liquid_il/structured_helpers.rb lib/liquid_il/filters.rb lib/liquid_il/utils.rb lib/liquid_il/context.rb spec/liquid_il_shopify.rb; do
  ruby -c "$f" > /dev/null 2>&1 || { echo "SYNTAX ERROR in $f"; echo "METRIC render_µs=999999"; echo "METRIC parse_µs=999999"; echo "METRIC render_allocs=999999"; echo "METRIC passed=0"; exit 0; }
done

# Run benchmark with YJIT
RESULTS=$(RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run spec/liquid_il_shopify.rb --bench --jit 2>&1)
CLEAN=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g')

# Check pass count
TOTAL_LINE=$(echo "$CLEAN" | grep "^  Tests:")
PASSED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
FAILED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "0")

if [ "$FAILED" != "0" ]; then
  echo "TESTS FAILED: $FAILED"
  echo "METRIC render_µs=999999"
  echo "METRIC parse_µs=999999"
  echo "METRIC render_allocs=999999"
  echo "METRIC passed=$PASSED"
  exit 0
fi

# Extract metrics from summary line
# Parse:  5.339 ms total, 184.118 µs avg (137,833 iters)
# Render: 84.526 ms total, 2.915 ms avg (25,072 iters)
# Allocs: 16,005 parse, 94,108 render
eval "$(ruby -e '
lines = STDIN.read
parse_line = lines[/Parse:.*total/]
render_line = lines[/Render:.*total/]
allocs_line = lines[/Allocs:.*render/]

if parse_line =~ /([0-9.]+)\s*ms\s*total/
  parse_us = ($1.to_f * 1000).round
elsif parse_line =~ /([0-9.]+)\s*µs\s*total/
  parse_us = $1.to_f.round
else
  parse_us = 0
end

if render_line =~ /([0-9.]+)\s*ms\s*total/
  render_us = ($1.to_f * 1000).round
elsif render_line =~ /([0-9.]+)\s*µs\s*total/
  render_us = $1.to_f.round
else
  render_us = 0
end

render_allocs = 0
if allocs_line =~ /([0-9,]+)\s*render/
  render_allocs = $1.gsub(",","").to_i
end

puts "PARSE_US=#{parse_us}"
puts "RENDER_US=#{render_us}"
puts "RENDER_ALLOCS=#{render_allocs}"
' <<< "$CLEAN")"

echo "METRIC render_µs=${RENDER_US}"
echo "METRIC parse_µs=${PARSE_US}"
echo "METRIC render_allocs=${RENDER_ALLOCS}"
echo "METRIC passed=${PASSED}"
