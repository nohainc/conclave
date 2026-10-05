#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_CLOUD_URL="${CONCLAVE_DEVELOPMENT_CLOUD_URL:-http://localhost:8787}"
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
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/profile_lab"
exec flutter run -d macos --debug \
  --dart-define="CONCLAVE_CLOUD_URL=$DEV_CLOUD_URL" \
  --dart-define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_ROOTS" "$@"
