#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
OUT_DIR="$ROOT/dist/conclave-workspace/service"
ENGINE_NAME="conclave_cli_worker_engine"
OUTPUT_NAME="conclave-service"
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  ENGINE_NAME="conclave_cli_worker_engine.exe"
  OUTPUT_NAME="conclave-service.exe"
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter SDK is required to resolve Workspace dependencies." >&2
  exit 1
}
command -v dart >/dev/null 2>&1 || {
  echo "Dart SDK is required to compile the Workspace service." >&2
  exit 1
}

VERSION="${CONCLAVE_WORKSPACE_VERSION:-1.0.3}"
if [[ -z "${CONCLAVE_WORKSPACE_VERSION:-}" ]]; then
  VERSION="$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")"
fi
PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-profile-trust.mjs")"

cd "$WORKSPACE_DIR"
flutter pub get
bash "$ROOT/scripts/build-cli-worker-engine.sh"
mkdir -p "$OUT_DIR/assets/engines"
cp "assets/engines/$ENGINE_NAME" "$OUT_DIR/assets/engines/"
dart compile exe \
  --define="CONCLAVE_WORKSPACE_VERSION=$VERSION" \
  --define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_RELEASE_ROOTS" \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  bin/conclave_workspace_service.dart \
  -o "$OUT_DIR/$OUTPUT_NAME"
echo "Built headless Workspace service at $OUT_DIR/$OUTPUT_NAME"
