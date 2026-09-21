#!/usr/bin/env bash
set -euo pipefail

version="${CONCLAVE_AGENT_VERSION:-0.2.0}"
executable="${CONCLAVE_AGENT_EXECUTABLE:-}"
output="${CONCLAVE_AGENT_PKG_OUTPUT:-dist/conclave-agent-${version}.pkg}"

if [[ -z "$executable" || ! -x "$executable" ]]; then
  echo "CONCLAVE_AGENT_EXECUTABLE must point to a signed executable" >&2
  exit 2
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
install_root="$stage/usr/local/lib/conclave-agent/$version"
mkdir -p "$install_root" "$(dirname "$output")"
install -m 0755 "$executable" "$install_root/conclave-agent"
ln -sfn "$version/conclave-agent" "$stage/usr/local/lib/conclave-agent/current"

pkgbuild \
  --root "$stage" \
  --identifier com.conclaveax.agent \
  --version "$version" \
  --install-location / \
  "$output"

echo "Built $output. Sign with productsign and notarize/staple before release."

