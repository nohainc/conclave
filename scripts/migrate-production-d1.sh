#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${CONCLAVE_PRODUCTION_D1_NAME:-conclave-v8-production}"
wrangler_config="${CONCLAVE_WRANGLER_CONFIG:-${repo_root}/infra/cloudflare/app.wrangler.jsonc}"

if [[ "${CONFIRM_PRODUCTION_MIGRATION:-}" != "YES" ]]; then
  cat >&2 <<'EOF'
Refusing to migrate production without explicit confirmation.

Review the pending migrations, then rerun with:
  CONFIRM_PRODUCTION_MIGRATION=YES ./scripts/migrate-production-d1.sh
EOF
  exit 2
fi

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

echo "Checking pending migrations for remote D1 database: $database_name"
pnpm exec wrangler d1 migrations list "$database_name" \
  --remote \
  --config "$wrangler_config"

echo "Applying pending migrations to remote D1 database: $database_name"
prepared_dir="$(mktemp -d "${TMPDIR:-/tmp}/conclave-d1-migration.XXXXXX")"
trap 'rm -rf "$prepared_dir"' EXIT
pnpm exec wrangler d1 execute "$database_name" \
  --remote --config "$wrangler_config" --json \
  --command "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type,name; SELECT name FROM d1_migrations WHERE name = '0006_chat_workflow_admission.sql';" \
  > "$prepared_dir/schema.json"
node scripts/prepare-chat-workflow-migration.mjs \
  "$prepared_dir/schema.json" "$wrangler_config" "$prepared_dir"
pnpm exec wrangler d1 migrations apply "$database_name" \
  --remote \
  --config "$prepared_dir/wrangler.json"

echo "Verifying migration state for remote D1 database: $database_name"
pnpm exec wrangler d1 migrations list "$database_name" \
  --remote \
  --config "$wrangler_config"

echo "Production D1 migration complete."
