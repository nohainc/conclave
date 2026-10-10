#!/usr/bin/env bash
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: $(basename "$0") '/path/to/Conclave Workspace.app'" >&2
  exit 2
fi

HELPER="$APP/Contents/Helpers/conclave-service"
ENGINE="$APP/Contents/Helpers/assets/engines/conclave_cli_worker_engine"
PLIST="$APP/Contents/Library/LaunchAgents/com.conclaveax.workspace.service.plist"
for path in "$HELPER" "$ENGINE" "$PLIST"; do
  [[ -e "$path" ]] || { echo "Missing service bundle item: $path" >&2; exit 1; }
done
[[ -x "$HELPER" && -x "$ENGINE" ]] || {
  echo "Service and Engine bundle items must be executable." >&2
  exit 1
}
/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" == "com.conclaveax.workspace.service" ]] || {
  echo "Unexpected LaunchAgent label." >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST")" == "Contents/Helpers/conclave-service" ]] || {
  echo "LaunchAgent does not point at the embedded service." >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST")" == "Contents/Helpers/conclave-service" ]] || {
  echo "LaunchAgent argv[0] does not identify the embedded service." >&2
  exit 1
}
if codesign -dv "$APP" >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$APP"
fi
echo "Workspace service bundle is structurally valid: $APP"
