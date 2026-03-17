#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")"

# Run liquid-spec and verify pass rate hasn't regressed
# Baseline: 4058 passed, 6 failed (pre-existing render isolation issues)
MIN_PASS=4058

# liquid-spec returns non-zero when there are failures, so don't use set -e
RESULTS=$(bundle exec liquid-spec run spec/liquid_il_structured.rb 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
TOTAL_LINE=$(echo "$RESULTS" | grep "^Total:" || true)

if [ -z "$TOTAL_LINE" ]; then
  echo "FAIL: liquid-spec produced no Total: line (crash?)"
  echo "$RESULTS" | tail -20
  exit 1
fi

PASSED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
FAILED=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
ERRORS=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+ errors' | grep -oE '[0-9]+' || true)
ERRORS=${ERRORS:-0}

echo "liquid-spec: ${PASSED} passed, ${FAILED} failed, ${ERRORS} errors"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: ${ERRORS} errors (crashes in generated code)"
  echo "$RESULTS" | grep -A3 "Error:" | tail -20
  exit 1
fi

if [ "$PASSED" -lt "$MIN_PASS" ]; then
  echo "FAIL: only ${PASSED} passed (need >= ${MIN_PASS})"
  echo "$RESULTS" | grep -B1 -A2 "^[0-9]*)" | tail -30
  exit 1
fi

echo "OK"
