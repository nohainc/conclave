#!/usr/bin/env bash
set -euo pipefail

version="${SYNTILA_AGENT_VERSION:-0.2.0}"
executable="${SYNTILA_AGENT_EXECUTABLE:-}"
output="${SYNTILA_AGENT_PKG_OUTPUT:-dist/syntila-agent-${version}.pkg}"

if [[ -z "$executable" || ! -x "$executable" ]]; then
  echo "SYNTILA_AGENT_EXECUTABLE must point to a signed executable" >&2
  exit 2
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
install_root="$stage/usr/local/lib/syntila-agent/$version"
mkdir -p "$install_root" "$(dirname "$output")"
install -m 0755 "$executable" "$install_root/syntila-agent"
ln -sfn "$version/syntila-agent" "$stage/usr/local/lib/syntila-agent/current"

pkgbuild \
  --root "$stage" \
  --identifier com.syntila.agent \
  --version "$version" \
  --install-location / \
  "$output"

echo "Built $output. Sign with productsign and notarize/staple before release."

