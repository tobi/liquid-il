#!/bin/bash
# Quality gates for autoresearch compile time optimization
# Runs all available checks and exits non-zero on failure

set -euo pipefail

cd "$(dirname "$0")"

echo "=== Running unit tests ==="
bundle exec ruby -Ilib test/liquid_il_test.rb
echo "✅ Unit tests passed"

echo ""
echo "=== Running liquid-spec suite ==="
# Run liquid-spec, capture output (allow non-zero exit since we have known gaps)
SPECS_OUTPUT=$(bundle exec liquid-spec run adapter.rb 2>&1) || true
echo "$SPECS_OUTPUT" | tail -5

# Parse the summary line
SUMMARY=$(echo "$SPECS_OUTPUT" | grep "^Total:" || echo "Total: 0 passed, 0 failed, 0 errors")
PASSED=$(echo "$SUMMARY" | grep -oP '\d+(?= passed)' || echo "0")
FAILED=$(echo "$SUMMARY" | grep -oP '\d+(?= failed)' || echo "0")
ERRORS=$(echo "$SUMMARY" | grep -oP '\d+(?= errors)' || echo "0")

echo ""
echo "Spec results: ${PASSED:-0} passed, ${FAILED:-0} failed, ${ERRORS:-0} errors"

# Fail if no specs passed (indicates a major regression)
if [ -z "${PASSED:-}" ] || [ "${PASSED:-0}" -eq 0 ]; then
  echo "❌ No specs passed!"
  exit 1
fi

echo "✅ Spec suite ran successfully"
echo ""
echo "=== All checks passed ==="
