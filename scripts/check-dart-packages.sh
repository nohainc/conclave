#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
dart format --output=none --set-exit-if-changed apps/app apps/workspace engines packages

check_dart_package() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    dart pub get
    dart analyze
    if [[ -d test ]]; then
      dart test
    fi
  )
}

for package_path in \
  packages/dart/protocol \
  packages/conclave_worker_protocol \
  packages/conclave_cli_worker_runtime \
  packages/tool_profile_v1 \
  engines/cli_worker
do
  check_dart_package "$package_path"
done

check_flutter_package() {
  local package_path="$1"
  local test_args=()
  if [[ "$package_path" == "apps/workspace" ]]; then
    test_args=(--concurrency=1)
  fi
  (
    cd "$ROOT/$package_path"
    flutter pub get
    flutter analyze
    if [[ "$package_path" == "apps/workspace" ]]; then
      DART_EXECUTABLE="$(command -v dart)" flutter test "${test_args[@]}"
    else
      flutter test
    fi
  )
}

check_flutter_package apps/workspace
check_flutter_package apps/app
