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
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SpawnConstraint:signing-identifier' "$PLIST")" == "conclave-service" ]] || {
  echo "LaunchAgent spawn constraint does not identify the embedded service." >&2
  exit 1
}

/usr/bin/plutil -lint "$PLIST" >/dev/null || {
  echo "LaunchAgent manifest is not valid plist data." >&2
  exit 1
}

if codesign -dv "$APP" >/dev/null 2>&1; then
  codesign --verify --strict --verbose=2 "$HELPER"
  codesign --verify --strict --verbose=2 "$ENGINE"
  codesign --verify --deep --strict --verbose=2 "$APP"

  team_id() {
    codesign -dv --verbose=4 "$1" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2; exit}'
  }
  identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 \
      | awk -F= '/^Identifier=/{print $2; exit}'
  }

  APP_TEAM_ID="$(team_id "$APP")"
  HELPER_TEAM_ID="$(team_id "$HELPER")"
  ENGINE_TEAM_ID="$(team_id "$ENGINE")"
  HELPER_IDENTIFIER="$(identifier "$HELPER")"
  [[ "$HELPER_IDENTIFIER" == "conclave-service" ]] || {
    echo "The signed service helper has an unexpected designated identifier: ${HELPER_IDENTIFIER:-missing}." >&2
    exit 1
  }

  # Apple-signed release bundles must have one signing team across the app,
  # service, and Worker Engine. Ad-hoc development signatures have no team
  # identifier and are intentionally allowed for UI-only development builds.
  if [[ -n "$APP_TEAM_ID" || -n "$HELPER_TEAM_ID" || -n "$ENGINE_TEAM_ID" ]]; then
    [[ -n "$APP_TEAM_ID" && "$APP_TEAM_ID" == "$HELPER_TEAM_ID" && "$APP_TEAM_ID" == "$ENGINE_TEAM_ID" ]] || {
      echo "Workspace app, service helper, and Worker Engine are not signed by the same team." >&2
      exit 1
    }
    CONSTRAINT_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :SpawnConstraint:team-identifier' "$PLIST" 2>/dev/null || true)"
    [[ "$CONSTRAINT_TEAM_ID" == "$HELPER_TEAM_ID" ]] || {
      echo "LaunchAgent team-identifier constraint does not match the signed service helper." >&2
      exit 1
    }
  fi
fi
echo "Workspace service bundle is structurally valid: $APP"
