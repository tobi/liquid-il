#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Quick syntax check on key files
for f in lib/liquid_il/structured_compiler.rb lib/liquid_il/context.rb lib/liquid_il/structured_helpers.rb lib/liquid_il/filters.rb; do
  ruby -c "$f" > /dev/null 2>&1 || { echo "SYNTAX ERROR in $f" >&2; echo "METRIC render_µs=0"; echo "METRIC parse_µs=0"; exit 1; }
done

# Run benchmark with YJIT
RESULTS=$(RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run spec/liquid_il_structured.rb -s benchmarks --bench 2>&1)

# Check for failures
if echo "$RESULTS" | grep -q "0 passed"; then
  echo "METRIC render_µs=0"
  echo "METRIC parse_µs=0"
  exit 1
fi

# Strip ANSI codes once
CLEAN=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g')

# Extract parse (always in ms) and render (ms or µs) values using ruby for reliable parsing
eval "$(ruby -e '
lines = STDIN.read
parse_line = lines[/Parse:.*total/]
render_line = lines[/Render:.*total/]

parse_val = parse_line[/([0-9.]+)\s*ms\s*total/, 1].to_f
# Render could be µs or ms
if render_line =~ /([0-9.]+)\s*ms\s*total/
  render_us = ($1.to_f * 1000).round
elsif render_line =~ /([0-9.]+)\s*.s\s*total/
  render_us = $1.to_f.round
end
parse_us = (parse_val * 1000).round

puts "PARSE_US=#{parse_us}"
puts "RENDER_US=#{render_us}"
' <<< "$CLEAN")"

# Extract alloc counts
ALLOCS=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g' | grep "Allocs:")
PARSE_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ parse' | grep -oE '[0-9,]+' | tr -d ',')
RENDER_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ render' | grep -oE '[0-9,]+' | tr -d ',')

echo "METRIC render_µs=${RENDER_US}"
echo "METRIC parse_µs=${PARSE_US}"
echo "METRIC render_allocs=${RENDER_ALLOCS}"
echo "METRIC parse_allocs=${PARSE_ALLOCS}"

# Supplemental metrics: code size, ISeq compile time, YJIT stats
# Runs quickly (~2s) after the main benchmark
SUPP=$(RUBY_YJIT_ENABLE=1 ruby -Ilib auto/supplemental-metrics.rb 2>/dev/null) || true
if [ -n "$SUPP" ]; then
  echo "$SUPP"
fi
