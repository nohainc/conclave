#!/usr/bin/env bash
set -euo pipefail

label="com.conclaveax.agent-engine"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
support_dir="${HOME}/Library/Application Support/Conclave AX"
app_destination="${HOME}/Applications/Conclave AX.app"
confirmed=false
purge=false
while (($# > 0)); do
  case "$1" in
    --confirm) confirmed=true ;;
    --purge) purge=true ;;
    -h|--help)
      echo "Usage: uninstall-agent-macos.sh --confirm [--purge]"
      echo "By default, preserves Agent data, logs, and credentials."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: uninstall-agent-macos.sh --confirm [--purge]" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$confirmed" != true ]]; then
  echo "Refusing to uninstall without --confirm" >&2
  echo "Usage: uninstall-agent-macos.sh --confirm [--purge]" >&2
  exit 2
fi

if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${label}"
fi
rm -f "$plist"
rm -rf "$app_destination"
if [[ "$purge" == true ]]; then
  rm -rf "$support_dir"
  echo "Removed Conclave AX Agent App, Engine service, and local Agent data."
else
  echo "Removed Conclave AX Agent App and Engine service; preserved local Agent data."
fi
