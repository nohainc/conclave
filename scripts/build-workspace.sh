#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="debug"
ALLOW_UNSIGNED="1"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) MODE=debug; shift ;;
    --release) MODE=release; ALLOW_UNSIGNED=0; shift ;;
    --version|-v) VERSION="$2"; shift 2 ;;
    --allow-signed-only) ALLOW_UNSIGNED=0; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--debug|--release] [--version X.Y.Z] [--allow-signed-only]"
      echo "Builds the Workspace desktop app for the current host OS. Debug builds enable local unsigned Worker packages by default."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

OS="$(uname -s)"
case "$OS" in
  Darwin)
    args=("--$MODE")
    [[ -n "$VERSION" ]] && args+=(--version "$VERSION")
    if [[ "$ALLOW_UNSIGNED" == 1 ]]; then args+=(--allow-unsigned-development-workers); fi
    exec bash "$ROOT/scripts/build-workspace-macos.sh" "${args[@]}"
    ;;
  Linux)
    target=linux
    ;;
  MINGW*|MSYS*|CYGWIN*)
    target=windows
    ;;
  *) echo "Unsupported desktop build host: $OS" >&2; exit 1 ;;
esac

HOST="$ROOT/apps/host"
command -v flutter >/dev/null 2>&1 || { echo "Flutter is required." >&2; exit 1; }
cd "$HOST"
flutter pub get
bash "$ROOT/scripts/build-cli-worker-engine.sh"
if [[ "$MODE" == debug ]]; then
  flutter build "$target" --debug \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}" \
    --dart-define=CONCLAVE_ENABLE_UNSIGNED_DEVELOPMENT_WORKERS="$([[ "$ALLOW_UNSIGNED" == 1 ]] && echo true || echo false)"
else
  flutter build "$target" --release \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
fi
echo "Workspace $MODE build finished for $target."
