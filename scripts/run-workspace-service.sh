#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"

if [[ ! -f "$WORKSPACE_DIR/.dart_tool/package_config.json" ]]; then
  echo "Workspace dependencies are not resolved. Run flutter pub get in apps/workspace first." >&2
  exit 1
fi

ENGINE="$WORKSPACE_DIR/assets/engines/conclave_cli_worker_engine"
if [[ ! -x "$ENGINE" ]]; then
  echo "The bundled CLI Worker Engine is missing. Run scripts/build-cli-worker-engine.sh first." >&2
  exit 1
fi

DART=""
if command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(dirname "$(command -v flutter)")"
  CACHED_DART="$FLUTTER_BIN/cache/dart-sdk/bin/dart"
  if [[ -x "$CACHED_DART" ]]; then DART="$CACHED_DART"; fi
fi
DART="${DART:-$(command -v dart || true)}"
[[ -n "$DART" ]] || {
  echo "Dart SDK is required to run the Workspace Service." >&2
  exit 1
}

cd "$WORKSPACE_DIR"
exec "$DART" run bin/conclave_workspace_service.dart --background-service "$@"
