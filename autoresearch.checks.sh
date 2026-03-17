#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")"

# Run liquid-spec and verify 0 failures, 0 errors
RESULTS=$(bundle exec liquid-spec run spec/liquid_il_structured.rb 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
TOTAL_LINE=$(echo "$RESULTS" | grep "^Total:" || true)

if [ -z "$TOTAL_LINE" ]; then
  echo "FAIL: liquid-spec produced no Total: line (crash?)"
  echo "$RESULTS" | tail -20
  exit 1
fi

PASSED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
FAILED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || true)
FAILED=${FAILED:-0}
ERRORS=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ errors' | grep -oE '[0-9]+' || true)
ERRORS=${ERRORS:-0}

echo "liquid-spec: ${PASSED} passed, ${FAILED} failed, ${ERRORS} errors"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: ${ERRORS} errors"
  echo "$RESULTS" | grep -A3 "Error:" | tail -20
  exit 1
fi

if [ "$FAILED" -gt 0 ]; then
  echo "FAIL: ${FAILED} failures"
  echo "$RESULTS" | grep -B1 -A2 "^[0-9]*)" | tail -30
  exit 1
fi

echo "OK"
