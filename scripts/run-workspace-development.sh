#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_CLOUD_URL="${CONCLAVE_DEVELOPMENT_CLOUD_URL:-http://localhost:8787}"
DEV_DRAFT_ROOT="${CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY:-}"
PUBLIC_ROOTS="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-}"
if [[ -z "$PUBLIC_ROOTS" ]]; then
  case "$DEV_CLOUD_URL" in
    http://localhost:*|http://127.0.0.1:*|http://\[::1\]:*)
      PUBLIC_ROOTS="$(node "$ROOT/scripts/setup-development-profile-signing.mjs" --public-trust)" ;;
    https://app.conclaveax.com)
      PUBLIC_ROOTS="$(node -e 'process.stdout.write(require("node:fs").readFileSync(process.argv[1], "utf8").trim())' "$ROOT/.development/hosted-profile-trust.json")" ;;
    *) echo "Supply CONCLAVE_RELEASE_TRUST_KEYS_JSON for this Cloud environment." >&2; exit 1 ;;
  esac
fi
DEV_STATE_ROOT="${CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR:-$HOME/Library/Application Support/Conclave/Workspace/DevelopmentState}"
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/workspace"
exec flutter run -d macos --debug \
  --dart-define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_ROOTS" \
  --dart-define="CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY=$DEV_DRAFT_ROOT" \
  --dart-entrypoint-args=--cloud-url \
  --dart-entrypoint-args="$DEV_CLOUD_URL" \
  --dart-entrypoint-args=--data-dir \
  --dart-entrypoint-args="$DEV_STATE_ROOT" "$@"
