#!/usr/bin/env bash
# Cross-compiles the headless install unit without touching native app assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64|arm64) ;; *) echo "Usage: $0 [x64|arm64]" >&2; exit 2 ;; esac
export CONCLAVE_WORKSPACE_PACKAGE_MANAGER=apt
export CONCLAVE_BUILD_TARGET_OS=linux CONCLAVE_BUILD_TARGET_ARCH="$ARCH"
bash "$ROOT/scripts/build-workspace-service.sh"
BUNDLE="$ROOT/dist/conclave-workspace/linux-$ARCH"
cp "$ROOT/docs/operations/WORKSPACE_LINUX.md" "$BUNDLE/README.md"
ARCHIVE="$ROOT/dist/conclave-workspace/conclave-workspace-headless-linux-$ARCH.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$BUNDLE" -czf "$ARCHIVE" .
echo "Built headless Linux bundle: $ARCHIVE"
