#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
OUT_DIR="$ROOT/dist/conclave-workspace/service"
TARGET_FLAGS=()
if [[ -n "${CONCLAVE_BUILD_TARGET_OS:-}${CONCLAVE_BUILD_TARGET_ARCH:-}" ]]; then
  [[ "${CONCLAVE_BUILD_TARGET_OS:-}" == linux ]] || { echo "Only Linux cross-builds are supported." >&2; exit 2; }
  case "${CONCLAVE_BUILD_TARGET_ARCH:-}" in x64|arm64) ;; *) echo "Target architecture must be x64 or arm64." >&2; exit 2 ;; esac
  TARGET_FLAGS=(--target-os=linux "--target-arch=$CONCLAVE_BUILD_TARGET_ARCH")
  OUT_DIR="$ROOT/dist/conclave-workspace/linux-$CONCLAVE_BUILD_TARGET_ARCH/service"
fi
ENGINE_NAME="conclave_cli_worker_engine"
OUTPUT_NAME="conclave-service"
if [[ -z "${CONCLAVE_BUILD_TARGET_OS:-}" ]] && [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  ENGINE_NAME="conclave_cli_worker_engine.exe"
  OUTPUT_NAME="conclave-service.exe"
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter SDK is required to resolve Workspace dependencies." >&2
  exit 1
}

# Invalidate any prior success marker before this build can fail. Packaging
# must never accept leftover executables after a failed rebuild.
if [[ "${CONCLAVE_BUILD_TARGET_OS:-}" == linux ]]; then
  rm -f "$OUT_DIR/build-manifest.json"
fi
command -v dart >/dev/null 2>&1 || {
  echo "Dart SDK is required to compile the Workspace service." >&2
  exit 1
}

VERSION="${CONCLAVE_WORKSPACE_VERSION:-1.0.3}"
if [[ -z "${CONCLAVE_WORKSPACE_VERSION:-}" ]]; then
  VERSION="$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")"
fi
PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-release-trust.mjs")"

cd "$WORKSPACE_DIR"
flutter pub get --enforce-lockfile
bash "$ROOT/scripts/build-cli-worker-engine.sh"
mkdir -p "$OUT_DIR/assets/engines"
ENGINE_SOURCE="$WORKSPACE_DIR/assets/engines/$ENGINE_NAME"
if [[ -n "${CONCLAVE_BUILD_TARGET_OS:-}" ]]; then
  ENGINE_SOURCE="$ROOT/dist/cli-worker-engine/linux-$CONCLAVE_BUILD_TARGET_ARCH/$ENGINE_NAME"
fi
cp "$ENGINE_SOURCE" "$OUT_DIR/assets/engines/"
dart compile exe ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"} \
  --define="CONCLAVE_WORKSPACE_VERSION=$VERSION" \
  --define="CONCLAVE_WORKSPACE_PACKAGE_MANAGER=${CONCLAVE_WORKSPACE_PACKAGE_MANAGER:-}" \
  --define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_RELEASE_ROOTS" \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  bin/conclave_workspace_service.dart \
  -o "$OUT_DIR/$OUTPUT_NAME"
CLI_NAME="conclave-workspace"
[[ "$OUTPUT_NAME" == *.exe ]] && CLI_NAME="conclave-workspace.exe"
dart compile exe ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"} \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  bin/conclave_workspace_cli.dart \
  -o "$OUT_DIR/$CLI_NAME"
echo "Built headless Workspace service at $OUT_DIR/$OUTPUT_NAME"
if [[ "${CONCLAVE_BUILD_TARGET_OS:-}" == linux ]]; then
  node "$ROOT/scripts/workspace-build-manifest.mjs" record "$OUT_DIR" "$VERSION"
fi
