#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec bash auto/parse_and_metrics.sh
