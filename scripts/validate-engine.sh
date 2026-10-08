#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

engine_packages=(
  packages/conclave_worker_protocol
  packages/tool_profile_v1
  packages/conclave_cli_worker_runtime
  engines/cli_worker
)

for pkg in "${engine_packages[@]}"; do
  echo "==> Validating $pkg"
  (
    cd "$ROOT/$pkg"
    dart pub get
    FORMAT_TARGETS=()
    if [[ -d lib ]]; then FORMAT_TARGETS+=(lib); fi
    if [[ -d test ]]; then FORMAT_TARGETS+=(test); fi
    if [[ -d bin ]]; then FORMAT_TARGETS+=(bin); fi
    if [[ ${#FORMAT_TARGETS[@]} -gt 0 ]]; then
      dart format --output=none --set-exit-if-changed "${FORMAT_TARGETS[@]}"
    fi
    dart analyze
    if [[ -d test ]]; then
      dart test
    fi
  )
done

echo "==> Engine validation passed."
