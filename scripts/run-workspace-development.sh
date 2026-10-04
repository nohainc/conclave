#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_CLOUD_URL="${CONCLAVE_DEVELOPMENT_CLOUD_URL:-http://localhost:8787}"
DEV_DRAFT_ROOT="${CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY:-$HOME/Library/Application Support/conclave.profile_lab/drafts}"
DEV_STATE_ROOT="${CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR:-$HOME/Library/Application Support/Conclave/Workspace/DevelopmentState}"
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/workspace"
exec flutter run -d macos --debug \
  --dart-define="CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY=$DEV_DRAFT_ROOT" \
  --dart-entrypoint-args=--cloud-url \
  --dart-entrypoint-args="$DEV_CLOUD_URL" \
  --dart-entrypoint-args=--data-dir \
  --dart-entrypoint-args="$DEV_STATE_ROOT" "$@"
