#!/usr/bin/env bash
# Builds the unsigned Linux Workspace bundle: Flutter management UI, the
# standalone conclave-service, and the canonical generic Worker Engine.
set -euo pipefail

MODE="${1:-release}"
if [[ "$MODE" != "release" && "$MODE" != "debug" ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Build Workspace for Linux on a Linux host (Flutter desktop cannot cross-compile)." >&2
  exit 1
fi
case "$(uname -m)" in
  x86_64) ARCH="x64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
for tool in flutter dart node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required." >&2; exit 1; }
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
SERVICE_BUILD="$ROOT/dist/conclave-workspace/service"
OUTPUT="$ROOT/dist/conclave-workspace/linux/$MODE"
ARCHIVE="$ROOT/dist/conclave-workspace/conclave-workspace-linux-$ARCH-$MODE.tar.gz"

# Reuse the canonical Engine and standalone service build.
bash "$ROOT/scripts/build-workspace-service.sh"

VERSION="$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")"
TRUST="$(node "$ROOT/scripts/resolve-build-release-trust.mjs")"
DEFINES="$(mktemp)"
trap 'rm -f "$DEFINES"' EXIT
node -e 'process.stdout.write(JSON.stringify({
  CONCLAVE_WORKSPACE_ENVIRONMENT: "production",
  CONCLAVE_WORKSPACE_VERSION: process.argv[1],
  CONCLAVE_RELEASE_TRUST_KEYS_JSON: process.argv[2],
}))' "$VERSION" "$TRUST" >"$DEFINES"
(cd "$WORKSPACE_DIR" && flutter build linux "--$MODE" "--dart-define-from-file=$DEFINES")

BUILD="$WORKSPACE_DIR/build/linux/$ARCH/$MODE/bundle"
# Only replace this build's output folder; never touch user state.
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp -R "$BUILD/." "$OUTPUT/"
cp "$SERVICE_BUILD/conclave-service" "$OUTPUT/"
# The standalone service discovers assets relative to its own executable; the
# Flutter UI uses its data/flutter_assets copy of the same Engine.
cp -R "$SERVICE_BUILD/assets" "$OUTPUT/"
cp "$ROOT/docs/operations/WORKSPACE_LINUX.md" "$OUTPUT/README.md"

DART_PAYLOAD="lib/libapp.so"
[[ "$MODE" == "debug" ]] && DART_PAYLOAD="data/flutter_assets/kernel_blob.bin"
for file in conclave_workspace lib/libflutter_linux_gtk.so "$DART_PAYLOAD" \
  data/flutter_assets/assets/engines/conclave_cli_worker_engine \
  assets/engines/conclave_cli_worker_engine conclave-service; do
  [[ -e "$OUTPUT/$file" ]] || { echo "Bundle is missing $file" >&2; exit 1; }
done
CANONICAL="$(sha256sum "$WORKSPACE_DIR/assets/engines/conclave_cli_worker_engine" | cut -d' ' -f1)"
for engine in "$OUTPUT/data/flutter_assets/assets/engines/conclave_cli_worker_engine" \
  "$OUTPUT/assets/engines/conclave_cli_worker_engine"; do
  [[ "$(sha256sum "$engine" | cut -d' ' -f1)" == "$CANONICAL" ]] || {
    echo "Bundled Engine does not match the canonical build: $engine" >&2
    exit 1
  }
done
chmod 755 "$OUTPUT/conclave_workspace" "$OUTPUT/conclave-service" \
  "$OUTPUT/assets/engines/conclave_cli_worker_engine"

tar -C "$OUTPUT" -czf "$ARCHIVE" .
echo "Built unsigned Linux Workspace bundle: $ARCHIVE"
