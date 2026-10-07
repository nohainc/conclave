#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

dart_packages=(
  packages/dart/protocol
  packages/conclave_worker_protocol
  packages/conclave_cli_worker_runtime
  packages/tool_profile_v1
  engines/cli_worker
)

flutter_packages=(
  packages/conclave_design
  apps/workspace
  apps/profile_lab
  apps/app
)

resolve_dart_package_dependencies() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    dart pub get
  )
}

resolve_flutter_package_dependencies() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    flutter pub get
  )
}

# Resolve every package first so local path dependencies and package configs
# exist before formatting, analysis, or tests validate the repository.
for package_path in "${dart_packages[@]}"; do
  resolve_dart_package_dependencies "$package_path"
done

for package_path in "${flutter_packages[@]}"; do
  resolve_flutter_package_dependencies "$package_path"
done

# Workspace acceptance tests exercise the Engine executable through the real
# Profile Lab and Workspace path; build it before Flutter starts those tests.
bash "$ROOT/scripts/build-cli-worker-engine.sh"

dart format --output=none --set-exit-if-changed apps engines packages

check_dart_package() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    dart analyze
    if [[ -d test ]]; then
      dart test
    fi
  )
}

for package_path in "${dart_packages[@]}"; do
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
    flutter analyze
    if [[ "$package_path" == "apps/workspace" ]]; then
      DART_EXECUTABLE="$(command -v dart)" flutter test "${test_args[@]}"
    else
      flutter test
    fi
  )
}

for package_path in "${flutter_packages[@]}"; do
  check_flutter_package "$package_path"
done
