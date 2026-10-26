#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_DRAFT_ROOT="${CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY:-}"
PUBLIC_ROOTS="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
DEV_STATE_ROOT="${CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR:-$HOME/Library/Application Support/Conclave/Workspace/DevelopmentState}"
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/workspace"
exec flutter run -d macos --debug \
  --dart-define="CONCLAVE_WORKSPACE_ENVIRONMENT=local" \
  --dart-define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_ROOTS" \
  --dart-define="CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY=$DEV_DRAFT_ROOT" \
  --dart-entrypoint-args=--data-dir \
  --dart-entrypoint-args="$DEV_STATE_ROOT" "$@"
