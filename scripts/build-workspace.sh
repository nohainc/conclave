#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="debug"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) MODE=debug; shift ;;
    --release) MODE=release; shift ;;
    --version|-v) VERSION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--debug|--release] [--version X.Y.Z]"
      echo "Builds the Workspace desktop app and bundled CLI Worker Engine for the current machine OS."
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
    exec bash "$ROOT/scripts/build-workspace-macos.sh" "${args[@]}"
    ;;
  Linux)
    target=linux
    ;;
  MINGW*|MSYS*|CYGWIN*)
    target=windows
    ;;
  *) echo "Unsupported desktop build machine: $OS" >&2; exit 1 ;;
esac

PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-profile-trust.mjs")"
WORKSPACE_DIR="$ROOT/apps/workspace"
command -v flutter >/dev/null 2>&1 || { echo "Flutter is required." >&2; exit 1; }
cd "$WORKSPACE_DIR"
flutter pub get
bash "$ROOT/scripts/build-cli-worker-engine.sh"
if [[ "$MODE" == debug ]]; then
  flutter build "$target" --debug \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="$PUBLIC_RELEASE_ROOTS"
else
  flutter build "$target" --release \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="$PUBLIC_RELEASE_ROOTS"
fi
echo "Workspace $MODE build finished for $target."
