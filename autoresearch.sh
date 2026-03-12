#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")"

# Quick syntax check
for f in lib/liquid_il/structured_compiler.rb lib/liquid_il/structured_helpers.rb lib/liquid_il/parser.rb; do
  ruby -c "$f" > /dev/null 2>&1 || { echo "METRIC failures=999"; echo "METRIC passed=0"; exit 0; }
done

# Run full spec suite
RESULTS=$(bundle exec liquid-spec run spec/liquid_il_structured.rb --max-failures 50 2>&1)
CLEAN=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g')

# Extract counts from "Total: N passed, N failed, N errors"
TOTAL_LINE=$(echo "$CLEAN" | grep "^Total:")
PASSED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
FAILED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "0")
ERRORS=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ errors' | grep -oE '[0-9]+' || echo "0")

FAILURES=$((FAILED + ERRORS))

echo "METRIC failures=${FAILURES}"
echo "METRIC passed=${PASSED}"

# Also run benchmark for speed regression tracking (only if tests mostly pass)
if [ "$FAILURES" -lt 20 ]; then
  BENCH=$(RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run spec/liquid_il_structured.rb -s benchmarks --bench 2>&1)
  BCLEAN=$(echo "$BENCH" | sed 's/\x1b\[[0-9;]*m//g')

  eval "$(ruby -e '
lines = STDIN.read
parse_line = lines[/Parse:.*total/]
render_line = lines[/Render:.*total/]
parse_val = parse_line[/([0-9.]+)\s*ms\s*total/, 1].to_f rescue 0
if render_line =~ /([0-9.]+)\s*ms\s*total/
  render_us = ($1.to_f * 1000).round
elsif render_line =~ /([0-9.]+)\s*.s\s*total/
  render_us = $1.to_f.round
else
  render_us = 0
end
parse_us = (parse_val * 1000).round
puts "PARSE_US=#{parse_us}"
puts "RENDER_US=#{render_us}"
' <<< "$BCLEAN")"

  echo "METRIC parse_µs=${PARSE_US}"
  echo "METRIC render_µs=${RENDER_US}"
fi
