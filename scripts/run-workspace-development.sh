#!/usr/bin/env bash
# Runs the Workspace service from Dart source against the local Cloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_DRAFT_ROOT="${CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY:-}"
PUBLIC_ROOTS="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
DEV_STATE_ROOT="${CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR:-$HOME/Library/Application Support/Conclave/Workspace/DevelopmentState}"
bash "$ROOT/scripts/build-cli-worker-engine.sh"
cd "$ROOT/apps/workspace"
dart pub get
# Local builds are pinned to the local Cloud URL (http://localhost:8787).
exec dart run \
  "-DCONCLAVE_WORKSPACE_ENVIRONMENT=local" \
  "-DCONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_ROOTS" \
  "-DCONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY=$DEV_DRAFT_ROOT" \
  bin/conclave_workspace_service.dart --background-service \
  --data-dir "$DEV_STATE_ROOT" "$@"
