#!/usr/bin/env bash
set -euo pipefail

label="com.conclaveax.agent-engine"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
support_dir="${HOME}/Library/Application Support/Conclave AX"
app_destination="${HOME}/Applications/Conclave AX.app"
case "${1:-}" in
  --confirm)
    ;;
  -h|--help)
    echo "Usage: uninstall-agent-macos.sh --confirm"
    exit 0
    ;;
  *)
    echo "Refusing to uninstall without --confirm" >&2
    echo "Usage: uninstall-agent-macos.sh --confirm" >&2
    exit 2
    ;;
esac

if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${label}"
fi
rm -f "$plist"
rm -rf "$app_destination" "$support_dir"
echo "Removed Conclave AX Agent App and Engine service."
