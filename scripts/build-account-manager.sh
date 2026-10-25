#!/usr/bin/env bash
# Build the native Conclave Accounts app from any working directory.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Conclave Accounts requires macOS to build." >&2
  exit 1
fi

for build_tool in swift codesign plutil; do
  if ! command -v "$build_tool" >/dev/null 2>&1; then
    echo "Missing required build tool: $build_tool. Install Xcode command-line tools." >&2
    exit 1
  fi
done

exec bash "$repo_root/scripts/build-account-manager-macos.sh" "$@"
