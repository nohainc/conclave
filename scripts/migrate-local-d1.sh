#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${CONCLAVE_LOCAL_D1_NAME:-conclave-development}"
wrangler_config="${CONCLAVE_WRANGLER_CONFIG:-${repo_root}/apps/cloud/wrangler.jsonc}"

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

echo "Inspecting local D1 schema before migration: $database_name"
prepared_dir="$(mktemp -d "${TMPDIR:-/tmp}/conclave-local-d1-migration.XXXXXX")"
trap 'rm -rf "$prepared_dir"' EXIT

if [[ -d apps/cloud/.wrangler/state ]]; then
  mkdir -p "$prepared_dir/.wrangler"
  cp -a apps/cloud/.wrangler/state "$prepared_dir/.wrangler/"
fi

pnpm exec wrangler d1 execute "$database_name" \
  --local --config "$wrangler_config" --json \
  --command "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type,name; SELECT name FROM d1_migrations WHERE name = '0006_chat_workflow_admission.sql';" \
  > "$prepared_dir/schema.json"

if ! node scripts/space-thread-schema-preflight.mjs "$prepared_dir/schema.json"; then
  node scripts/prepare-space-thread-cutover.mjs \
    "$prepared_dir/schema.json" "$wrangler_config" "$prepared_dir/cutover"
  echo "Applying Space/Thread cutover: $database_name (local)"
  pnpm exec wrangler d1 migrations apply "$database_name" \
    --local --config "$prepared_dir/cutover/wrangler.json"
  pnpm exec wrangler d1 execute "$database_name" \
    --local --config "$wrangler_config" --json \
    --command "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type,name; SELECT name FROM d1_migrations WHERE name = '0006_chat_workflow_admission.sql';" \
    > "$prepared_dir/schema.json"
  node scripts/space-thread-schema-preflight.mjs "$prepared_dir/schema.json"
fi

node scripts/prepare-chat-workflow-migration.mjs \
  "$prepared_dir/schema.json" "$wrangler_config" "$prepared_dir"

echo "Applying pending local migrations: $database_name"
echo y | pnpm exec wrangler d1 migrations apply "$database_name" \
  --local \
  --config "$prepared_dir/wrangler.json"

if [[ -d "$prepared_dir/.wrangler/state/v3/d1/miniflare-D1DatabaseObject" ]]; then
  mkdir -p apps/cloud/.wrangler/state/v3/d1/miniflare-D1DatabaseObject
  cp -a "$prepared_dir/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/"* apps/cloud/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/
fi

echo "Local D1 migration complete."
