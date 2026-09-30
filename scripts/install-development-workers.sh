#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    echo "Usage: $(basename "$0") [--worker chatgpt|gemini|all] [--worker ...] [--artifact-root DIR] [--data-dir DIR] [--no-activate]"
    exit 0
  fi
done
cd "$ROOT/apps/host"
command -v flutter >/dev/null 2>&1 || { echo "Flutter is required." >&2; exit 1; }
flutter pub get
exec dart run bin/install_development_workers.dart "$@"
