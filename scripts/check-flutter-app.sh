#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
case "$APP" in
  workspace|profile_lab|app) ;;
  *) echo "Usage: check-flutter-app.sh workspace|profile_lab|app [--prepared]" >&2; exit 1 ;;
esac
shift
PREPARED=0
if [[ "${1:-}" == "--prepared" ]]; then PREPARED=1; shift; fi
[[ $# == 0 ]] || { echo "Unknown argument: $1" >&2; exit 1; }
cd "$ROOT/apps/$APP"
if [[ "$PREPARED" == 0 ]]; then
  flutter pub get
  if [[ "$APP" != app ]]; then
    bash "$ROOT/scripts/build-cli-worker-engine.sh"
  fi
else
  [[ -f .dart_tool/package_config.json ]] || { echo "Resolve dependencies first." >&2; exit 1; }
  if [[ "$APP" != app && ! -x assets/engines/conclave_cli_worker_engine ]]; then
    echo "Build the Engine before prepared app checks." >&2; exit 1
  fi
fi
FORMAT_PATHS=(lib test)
if [[ -d bin ]]; then FORMAT_PATHS+=(bin); fi
dart format --output=none --set-exit-if-changed "${FORMAT_PATHS[@]}"
flutter analyze
if [[ "$APP" == workspace ]]; then
  DART_EXECUTABLE="$(command -v dart)" flutter test --concurrency=1
  bash "$ROOT/scripts/check-workspace-service.sh"
else
  flutter test
fi
