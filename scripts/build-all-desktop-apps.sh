#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="debug"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --debug|--release)
      MODE="${1#--}"
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--debug|--release] [--version X.Y.Z]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
ARGS=("--$MODE")
[[ -n "$VERSION" ]] && ARGS+=(--version "$VERSION")
bash "$ROOT/scripts/build-workspace.sh" "${ARGS[@]}"
echo "Built the Workspace desktop app and bundled CLI Worker Engine for this host."
