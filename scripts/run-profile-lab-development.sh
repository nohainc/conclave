#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_CLOUD_URL="${CONCLAVE_DEVELOPMENT_CLOUD_URL:-http://localhost:8787}"
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/profile_lab"
exec flutter run -d macos --debug \
  --dart-define="CONCLAVE_CLOUD_URL=$DEV_CLOUD_URL" "$@"
