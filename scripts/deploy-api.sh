#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/infra/cloudflare/app.wrangler.jsonc}"

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

# Ensure assets directory exists for wrangler config schema requirement
mkdir -p apps/app/build/web
if [[ ! -f apps/app/build/web/index.html ]]; then
  echo "Flutter web assets are missing from apps/app/build/web." >&2
  echo "Build the web app first with: flutter build web --release --dart-define=SYNTILA_API_URL=/api" >&2
  exit 1
fi

echo "Deploying Syntila Cloud API Worker (conclave-ax-app)..."
pnpm exec wrangler deploy --config "$wrangler_config" "$@"

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "Verifying production D1 schema..."
  node scripts/production-workspace-gateway-smoke.mjs --schema-only
fi

echo "Syntila API deployment complete."
