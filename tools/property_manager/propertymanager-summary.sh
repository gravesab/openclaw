#!/usr/bin/env bash
set -euo pipefail

BASE="${OPENCLAW_BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
python3 "$BASE/tools/property_manager/propertymanager-summary.py"
