#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_LAB_DIR="$ROOT/apps/profile_lab"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Conclave Profile Lab macOS tests must run on macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Runs formatting check, static analysis, unit tests, and integration tests for Profile Lab."
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

bash "$ROOT/scripts/check-flutter-app.sh" profile_lab
