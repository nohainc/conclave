#!/usr/bin/env bash
# Runs the Workspace service from Dart source against the local Cloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_DRAFT_ROOT="${CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY:-}"
PUBLIC_ROOTS="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
# Same state directory a --local build (conclave-workspace-local) uses, so the
# local CLI can talk to this service. It is kept apart from production state.
LOCAL_STATE_ROOT="$HOME/Library/Application Support/Conclave Local/Workspace/State"
LEGACY_STATE_ROOT="$HOME/Library/Application Support/Conclave/Workspace/DevelopmentState"
if [[ -n "${CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR:-}" ]]; then
  DEV_STATE_ROOT="$CONCLAVE_WORKSPACE_DEVELOPMENT_DATA_DIR"
elif [[ -d "$LEGACY_STATE_ROOT" && ! -d "$LOCAL_STATE_ROOT" ]]; then
  DEV_STATE_ROOT="$LEGACY_STATE_ROOT"
  echo "Using legacy development state at $LEGACY_STATE_ROOT." >&2
  echo "Move it to $LOCAL_STATE_ROOT to share it with conclave-workspace-local." >&2
else
  DEV_STATE_ROOT="$LOCAL_STATE_ROOT"
fi
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
