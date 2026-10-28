#!/usr/bin/env bash
# Clears orphaned execution state (stale Thread leases, never-launched
# assignments, stuck queued Work Requests) from the LOCAL development D1.
# Stop `pnpm app:run:local` first. Never touches production.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${SYNTILA_LOCAL_D1_NAME:-syntila-development}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/apps/cloud/wrangler.jsonc}"
cd "$repo_root"
pnpm exec wrangler d1 execute "$database_name" --local \
  --config "$wrangler_config" \
  --file "$repo_root/scripts/sql/cleanup-stale-execution-state.sql"
