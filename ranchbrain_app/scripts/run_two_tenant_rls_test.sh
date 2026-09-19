#!/usr/bin/env bash
set -euo pipefail

# Requires a disposable DEV database URL in RANCHOS_TENANCY_TEST_DATABASE_URL.
# It applies the migration and rolls back the two-tenant proof transaction.
: "${RANCHOS_TENANCY_TEST_DATABASE_URL:?Set a disposable DEV database URL before running this test.}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"

psql "$RANCHOS_TENANCY_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f "$project_dir/migrations/001_ranch_os_tenancy_foundation.sql" \
  -f "$project_dir/tests/rls/two_tenant_isolation.sql"
