#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$ROOT/engines/cli_worker"
OUTPUT_DIR="$ROOT/apps/workspace/assets/engines"
DART_BIN="${CONCLAVE_DART_EXECUTABLE:-$(command -v dart || true)}"

if [[ -z "$DART_BIN" ]]; then
  echo "Dart SDK is required to build the CLI Worker Engine." >&2
  exit 1
fi
DART_DIR="$(cd "$(dirname "$DART_BIN")" && pwd)"
if [[ -z "${CONCLAVE_DART_EXECUTABLE:-}" && -x "$DART_DIR/cache/dart-sdk/bin/dart" ]]; then
  DART_BIN="$DART_DIR/cache/dart-sdk/bin/dart"
fi

VERSION="$(awk '/^version:/ {print $2; exit}' "$ENGINE_DIR/pubspec.yaml")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CLI Worker Engine version must be stable semantic version text." >&2
  exit 1
fi
if [[ ! -f "$ENGINE_DIR/.dart_tool/package_config.json" ]]; then
  (cd "$ENGINE_DIR" && "$DART_BIN" pub get --enforce-lockfile)
fi

mkdir -p "$OUTPUT_DIR"
if [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
  OUTPUT="$OUTPUT_DIR/conclave_cli_worker_engine.exe"
else
  OUTPUT="$OUTPUT_DIR/conclave_cli_worker_engine"
fi
(cd "$ENGINE_DIR" && "$DART_BIN" compile exe \
  "-DENGINE_VERSION=$VERSION" \
  bin/conclave_cli_worker.dart \
  -o "$OUTPUT")
if [[ "$OUTPUT" != *.exe ]]; then chmod 755 "$OUTPUT"; fi
echo "Built generic CLI Worker Engine $VERSION: $OUTPUT"
