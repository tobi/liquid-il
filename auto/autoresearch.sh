#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Quick syntax check on key files
ruby -c lib/liquid_il/structured_compiler.rb > /dev/null 2>&1 || { echo "METRIC render_µs=0"; echo "METRIC parse_µs=0"; exit 1; }
ruby -c lib/liquid_il/context.rb > /dev/null 2>&1 || { echo "METRIC render_µs=0"; echo "METRIC parse_µs=0"; exit 1; }
ruby -c lib/liquid_il/structured_helpers.rb > /dev/null 2>&1 || { echo "METRIC render_µs=0"; echo "METRIC parse_µs=0"; exit 1; }

# Run benchmark with YJIT
RESULTS=$(RUBY_YJIT_ENABLE=1 bundle exec liquid-spec run spec/liquid_il_structured.rb -s benchmarks --bench 2>&1)

# Check for failures
if echo "$RESULTS" | grep -q "0 passed"; then
  echo "METRIC render_µs=0"
  echo "METRIC parse_µs=0"
  exit 1
fi

# Extract totals (in ms) and convert to µs
PARSE_MS=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g' | grep "Parse:" | grep -oE '[0-9]+\.[0-9]+ ms total' | grep -oE '[0-9]+\.[0-9]+')
RENDER_MS=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g' | grep "Render:" | grep -oE '[0-9]+\.[0-9]+ [mµ]s total' | head -1)

# Handle µs vs ms
if echo "$RENDER_MS" | grep -q "µs"; then
  RENDER_US=$(echo "$RENDER_MS" | grep -oE '[0-9]+\.[0-9]+')
else
  RENDER_VAL=$(echo "$RENDER_MS" | grep -oE '[0-9]+\.[0-9]+')
  RENDER_US=$(ruby -e "puts (${RENDER_VAL} * 1000).round")
fi

PARSE_US=$(ruby -e "puts (${PARSE_MS} * 1000).round")

# Extract alloc counts
ALLOCS=$(echo "$RESULTS" | sed 's/\x1b\[[0-9;]*m//g' | grep "Allocs:")
PARSE_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ parse' | grep -oE '[0-9,]+' | tr -d ',')
RENDER_ALLOCS=$(echo "$ALLOCS" | grep -oE '[0-9,]+ render' | grep -oE '[0-9,]+' | tr -d ',')

echo "METRIC render_µs=${RENDER_US}"
echo "METRIC parse_µs=${PARSE_US}"
echo "METRIC render_allocs=${RENDER_ALLOCS}"
echo "METRIC parse_allocs=${PARSE_ALLOCS}"
