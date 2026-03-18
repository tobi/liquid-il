#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
exec bash auto/checks.sh
