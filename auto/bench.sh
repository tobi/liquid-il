#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Quick correctness check: run full test suite first
FULL_OUTPUT=$(bundle exec liquid-spec run spec/liquid_il_structured.rb 2>&1)
FULL_EXIT=$?
if [ $FULL_EXIT -ne 0 ]; then
  echo "$FULL_OUTPUT"
  echo "CORRECTNESS GATE FAILED"
  echo "BENCH_METRIC=0"
  exit 1
fi
# Show pass count
echo "$FULL_OUTPUT" | grep 'passed'

# Clear stale results
rm -f /tmp/liquid-spec/liquid_il_structured.jsonl

# Run benchmarks, capture output
OUTPUT=$(bundle exec liquid-spec run spec/liquid_il_structured.rb -b -s benchmarks 2>&1)
EXIT_CODE=$?

# Print full output for debugging
echo "$OUTPUT"

# Check for failures
if [ $EXIT_CODE -ne 0 ]; then
  echo "BENCH_METRIC=0"
  exit 1
fi

# Extract total render time in µs from the JSONL results
RESULTS_FILE="/tmp/liquid-spec/liquid_il_structured.jsonl"
if [ ! -f "$RESULTS_FILE" ]; then
  echo "ERROR: Results file not found"
  echo "BENCH_METRIC=0"
  exit 1
fi

# Sum render_mean across all result entries (in µs), print as metric
# Also count passed/failed specs
METRIC=$(ruby -rjson -e '
  total = 0.0
  count = 0
  passed = 0
  failed = 0
  STDIN.each_line do |line|
    d = JSON.parse(line)
    next unless d["type"] == "result"
    total += d["render_mean"] * 1_000_000  # seconds to µs
    count += 1
    if d["status"] == "success"
      passed += 1
    else
      failed += 1
    end
  end
  if count == 0
    puts "0"
    exit 1
  end
  $stderr.puts "Specs: #{passed} passed, #{failed} failed out of #{count}"
  if failed > 0
    $stderr.puts "ERROR: #{failed} specs failed"
    puts "0"
    exit 1
  end
  puts total.round(1)
' < "$RESULTS_FILE")

echo "BENCH_METRIC=$METRIC"
