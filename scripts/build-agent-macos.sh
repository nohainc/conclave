#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

(cd apps/agent_app && \
  flutter build macos --release --build-name="${CONCLAVE_AGENT_VERSION:-0.1.0}")
dart compile exe apps/agent_engine/bin/conclave_agent_engine.dart \
  -o apps/agent_app/build/macos/Build/Products/Release/conclave_agent_engine

echo "Unsigned macOS Agent bundle and Engine produced under apps/agent_app/build/macos."
echo "Package with scripts/package-agent-macos.sh after signing identities are configured."
