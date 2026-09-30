#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER="all"
VERSION="${WORKER_VERSION:-}"
OUTPUT="$ROOT/dist/workers"
RESOLVE_DEPENDENCIES="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) WORKER="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --resolve-dependencies) RESOLVE_DEPENDENCIES="1"; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--worker chatgpt|gemini|all] [--version X.Y.Z[-suffix]] [--output DIR] [--resolve-dependencies]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != /* ]]; then OUTPUT="$ROOT/$OUTPUT"; fi

if [[ "$WORKER" != "all" && "$WORKER" != "chatgpt" && "$WORKER" != "gemini" ]]; then
  echo "--worker must be chatgpt, gemini, or all." >&2
  exit 2
fi
if [[ -z "$VERSION" ]]; then
  VERSION="0.0.0-dev.$(date -u +%Y%m%d%H%M%S)"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Worker version must be semantic version text." >&2
  exit 2
fi
DART_BIN="${CONCLAVE_DART_EXECUTABLE:-$(command -v dart || true)}"
if [[ -z "$DART_BIN" ]]; then
  echo "Dart SDK is required to build Workers." >&2
  exit 1
fi
DART_DIR="$(cd "$(dirname "$DART_BIN")" && pwd)"
if [[ -z "${CONCLAVE_DART_EXECUTABLE:-}" && -x "$DART_DIR/cache/dart-sdk/bin/dart" ]]; then
  DART_BIN="$DART_DIR/cache/dart-sdk/bin/dart"
fi
command -v node >/dev/null 2>&1 || { echo "Node.js is required only for development archive packaging." >&2; exit 1; }

platform_os="$(uname -s)"
platform_arch="$(uname -m)"
case "$platform_os" in
  Darwin) platform_os=macos ;;
  Linux) platform_os=linux ;;
  MINGW*|MSYS*|CYGWIN*) platform_os=windows ;;
  *) echo "Unsupported build OS: $platform_os" >&2; exit 1 ;;
esac
case "$platform_arch" in
  arm64|aarch64) platform_arch=arm64 ;;
  x86_64|amd64) platform_arch=x64 ;;
  *) echo "Unsupported build architecture: $platform_arch" >&2; exit 1 ;;
esac
platform="$platform_os-$platform_arch"
extension=""
[[ "$platform_os" == windows ]] && extension=".exe"

mkdir -p "$OUTPUT/$platform"
for worker_id in chatgpt gemini; do
  [[ "$WORKER" == all || "$WORKER" == "$worker_id" ]] || continue
  package="$ROOT/workers/$worker_id"
  worker_output="$OUTPUT/$platform/$worker_id"
  mkdir -p "$worker_output"
  if [[ "$RESOLVE_DEPENDENCIES" == "1" || ! -f "$package/.dart_tool/package_config.json" ]]; then
    (cd "$package" && "$DART_BIN" pub get --enforce-lockfile)
  fi
  (cd "$package" && "$DART_BIN" compile exe \
    -DWORKER_VERSION="$VERSION" \
    "bin/${worker_id}_worker.dart" \
    -o "$worker_output/conclave-${worker_id}-worker${extension}")
  if [[ "$platform_os" != windows ]]; then
    chmod 755 "$worker_output/conclave-${worker_id}-worker"
  fi
  node "$ROOT/scripts/package-development-worker.mjs" \
    "$worker_id" "$VERSION" "$OUTPUT"
done
echo "Built unsigned local-development Workers for $platform in $OUTPUT/$platform"
