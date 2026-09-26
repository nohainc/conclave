#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLOUD_URL="${CONCLAVE_CLOUD_URL:-https://app.conclaveax.com}"
TOKEN="${CONCLAVE_ENROLLMENT_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  cat >&2 <<'EOF'
CONCLAVE_ENROLLMENT_TOKEN is required.

Create a disposable Workspace in Conclave AX, choose "Connect machine", then run:

  CONCLAVE_ENROLLMENT_TOKEN='conclave_enroll_...' \
    ./scripts/test-workspace-cloud-connection.sh

Optionally set CONCLAVE_CLOUD_URL for local/staging Cloud.
The one-time code is consumed and the test creates a real Workspace runtime identity.
EOF
  exit 64
fi

cd "$ROOT/apps/host"
dart run bin/workspace_cloud_smoke.dart \
  --cloud-url "$CLOUD_URL" \
  --enrollment-token "$TOKEN"
