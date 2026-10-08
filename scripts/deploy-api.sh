#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrangler_config="${CONCLAVE_WRANGLER_CONFIG:-${repo_root}/infra/cloudflare/app.wrangler.jsonc}"

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

# Ensure assets directory exists for wrangler config schema requirement
mkdir -p apps/app/build/web

echo "Deploying Conclave Cloud API Worker (conclave-ax-app)..."
pnpm exec wrangler deploy --config "$wrangler_config" "$@"

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "Verifying production D1 schema..."
  node scripts/production-workspace-gateway-smoke.mjs --schema-only
fi

echo "Conclave API deployment complete."
