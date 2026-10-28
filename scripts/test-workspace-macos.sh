#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Workspace macOS tests must run on macOS." >&2
  exit 1
fi

command -v dart >/dev/null 2>&1 || {
  echo "The Dart SDK is required." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Runs static analysis and the test suite for the Syntila Workspace."
      echo ""
      echo "Options:"
      echo "  --help, -h  Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "Running Syntila Workspace macOS analysis and tests"
cd "$WORKSPACE_DIR"
dart pub get
echo "Running static analysis..."
dart analyze
echo "Running test suite..."
dart test
echo "All checks passed."
