#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export RUBYOPT="--yjit"

# Run full test suite (correctness gate)
FULL_OUTPUT=$(bundle exec liquid-spec run spec/liquid_il_structured.rb 2>&1)
FULL_EXIT=$?

# Extract pass/fail counts
PASSED=$(echo "$FULL_OUTPUT" | ruby -e '
  STDIN.each_line do |l|
    if l =~ /Total:\s*(\d+)\s*passed(?:,\s*(\d+)\s*failed)?/
      puts $1
      exit
    end
  end
  puts "0"
')
FAILED=$(echo "$FULL_OUTPUT" | ruby -e '
  STDIN.each_line do |l|
    if l =~ /Total:\s*\d+\s*passed,\s*(\d+)\s*failed/
      puts $1
      exit
    end
  end
  puts "0"
')

echo "Tests: ${PASSED} passed, ${FAILED} failed"

if [ "$FULL_EXIT" -ne 0 ] || [ "$FAILED" -gt 0 ]; then
  echo "$FULL_OUTPUT" | tail -30
  echo "BENCH_RENDER=0"
  echo "BENCH_COMPILE=0"
  echo "BENCH_FAILED=${FAILED}"
  echo "BENCH_METRIC=0"
  exit 1
fi

# Clear stale results
rm -f /tmp/liquid-spec/liquid_il_structured.jsonl

# Run benchmarks
OUTPUT=$(bundle exec liquid-spec run spec/liquid_il_structured.rb -b -s benchmarks 2>&1)
BENCH_EXIT=$?

echo "$OUTPUT"

if [ $BENCH_EXIT -ne 0 ]; then
  echo "BENCH_RENDER=0"
  echo "BENCH_COMPILE=0"
  echo "BENCH_FAILED=${FAILED}"
  echo "BENCH_METRIC=0"
  exit 1
fi

RESULTS_FILE="/tmp/liquid-spec/liquid_il_structured.jsonl"
if [ ! -f "$RESULTS_FILE" ]; then
  echo "ERROR: Results file not found"
  echo "BENCH_RENDER=0"
  echo "BENCH_COMPILE=0"
  echo "BENCH_FAILED=${FAILED}"
  echo "BENCH_METRIC=0"
  exit 1
fi

# Extract all metrics from JSONL
ruby -rjson -e '
  render_total = 0.0
  compile_total = 0.0
  count = 0
  bench_passed = 0
  bench_failed = 0

  STDIN.each_line do |line|
    d = JSON.parse(line)
    next unless d["type"] == "result"
    count += 1
    render_total += d["render_mean"] * 1_000_000   # to µs
    compile_total += d["parse_mean"] * 1_000_000    # to µs (parse = compile in this adapter)

    if d["status"] == "success"
      bench_passed += 1
    else
      bench_failed += 1
    end
  end

  if count == 0 || bench_failed > 0
    $stderr.puts "Benchmark failure: #{bench_failed}/#{count} specs failed"
    puts "BENCH_RENDER=0"
    puts "BENCH_COMPILE=0"
    puts "BENCH_FAILED=#{bench_failed}"
    puts "BENCH_METRIC=0"
    exit 1
  end

  # Primary metric = compile + render combined (total template cost)
  combined = compile_total + render_total
  puts "BENCH_RENDER=#{render_total.round(1)}"
  puts "BENCH_COMPILE=#{compile_total.round(1)}"
  puts "BENCH_FAILED=0"
  puts "BENCH_METRIC=#{combined.round(1)}"
' < "$RESULTS_FILE"
