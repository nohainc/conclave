#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package-agent-macos.sh --app-bundle PATH --engine PATH --output PATH
       [--version VERSION] [--signing-identity ID] [--require-signature]

Creates a distributable Conclave AX Agent zip. Codesigning is optional for
local builds. Release packaging must pass --require-signature (or set
CONCLAVE_REQUIRE_SIGNATURE=1) so unsigned archives cannot be produced.
EOF
}

app_bundle=""
engine=""
output=""
version="${CONCLAVE_AGENT_VERSION:-0.1.0}"
signing_identity="${CONCLAVE_CODESIGN_IDENTITY:-}"
require_signature="${CONCLAVE_REQUIRE_SIGNATURE:-0}"

while (($# > 0)); do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app_bundle="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      engine="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    --signing-identity)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --require-signature)
      require_signature=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_bundle" && -d "$app_bundle" ]] || {
  echo "Agent App bundle does not exist: $app_bundle" >&2
  exit 1
}
[[ -n "$engine" && -f "$engine" ]] || {
  echo "Agent Engine executable does not exist: $engine" >&2
  exit 1
}
[[ -n "$output" ]] || { usage >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || {
  echo "Invalid Agent version: $version" >&2
  exit 2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/conclave-agent-package.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

mkdir -p "$stage/Conclave AX Agent/bin" "$stage/Conclave AX Agent/scripts"
cp -R "$app_bundle" "$stage/Conclave AX Agent/"
install -m 0755 "$engine" "$stage/Conclave AX Agent/bin/conclave_agent_engine"
install -m 0755 "$repo_root/scripts/install-agent-macos.sh" \
  "$stage/Conclave AX Agent/scripts/install-agent-macos.sh"
install -m 0755 "$repo_root/scripts/uninstall-agent-macos.sh" \
  "$stage/Conclave AX Agent/scripts/uninstall-agent-macos.sh"

signed=false
if [[ -n "$signing_identity" ]]; then
  command -v codesign >/dev/null 2>&1 || {
    echo "codesign is required when --signing-identity is supplied" >&2
    exit 1
  }
  codesign --deep --force --options runtime --sign "$signing_identity" \
    "$stage/Conclave AX Agent/Conclave AX.app"
  codesign --force --options runtime --sign "$signing_identity" \
    "$stage/Conclave AX Agent/bin/conclave_agent_engine"
  signed=true
fi

if [[ "$require_signature" == "1" && "$signed" != "true" ]]; then
  echo "A signing identity is required for release packaging" >&2
  exit 1
fi

engine_digest="$(shasum -a 256 "$stage/Conclave AX Agent/bin/conclave_agent_engine" | awk '{print $1}')"
cat > "$stage/Conclave AX Agent/release.json" <<EOF
{
  "product": "conclave-agent",
  "version": "$version",
  "operatingSystem": "macos",
  "architecture": "$(uname -m)",
  "signed": $signed,
  "engineSha256": "$engine_digest",
  "installer": "scripts/install-agent-macos.sh",
  "uninstaller": "scripts/uninstall-agent-macos.sh"
}
EOF

mkdir -p "$(dirname "$output")"
ditto -c -k --sequesterRsrc --keepParent \
  "$stage/Conclave AX Agent" "$output"
echo "Created $output"
