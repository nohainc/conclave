#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_ARGS=(--worker all)
WORKSPACE_ARGS=(--debug)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      WORKER_ARGS+=(--version "$2")
      WORKSPACE_ARGS+=(--version "$2")
      shift 2
      ;;
    --release)
      echo "The all-in-one development build only creates unsigned development Workers; use build-workspace.sh --release for a signed-only Workspace." >&2
      exit 2
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--version X.Y.Z]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
bash "$ROOT/scripts/build-workers.sh" "${WORKER_ARGS[@]}"
bash "$ROOT/scripts/build-workspace.sh" "${WORKSPACE_ARGS[@]}"
echo "Built the Workspace desktop app and native ChatGPT/Gemini Workers for this host."
