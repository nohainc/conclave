#!/usr/bin/env bash
set -euo pipefail

# Verifies a built macOS Workspace bundle directory: the unified
# `syntila` binary and the generic CLI Worker Engine, plus their
# signatures when signed.
BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -d "$BUNDLE" ]]; then
  echo "Usage: $(basename "$0") '/path/to/syntila'" >&2
  exit 2
fi

BINARY="$BUNDLE/syntila"
ENGINE="$BUNDLE/assets/engines/syntila-agent"
for path in "$BINARY" "$ENGINE"; do
  [[ -e "$path" ]] || { echo "Missing bundle item: $path" >&2; exit 1; }
done
[[ -x "$BINARY" && -x "$ENGINE" ]] || {
  echo "The service binary and Engine must be executable." >&2
  exit 1
}

if codesign -dv "$BINARY" >/dev/null 2>&1; then
  team_id() {
    codesign -dv --verbose=4 "$1" 2>&1 \
      | awk -F= '/^TeamIdentifier=/ && $2 != "not set" && $2 != "" && !s{print $2; s=1}'
  }
  identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 \
      | awk -F= '/^Identifier=/ && !s{print $2; s=1}'
  }

  codesign --verify --strict --verbose=2 "$BINARY"
  codesign --verify --strict --verbose=2 "$ENGINE"

  # Dart AOT executables are hardened-runtime code and need the helper
  # entitlements, otherwise launchd can terminate the service with
  # OS_REASON_CODESIGNING even though a shallow signature check succeeds.
  BINARY_ENTITLEMENTS="$(codesign -d --entitlements :- "$BINARY" 2>/dev/null || true)"
  ENGINE_ENTITLEMENTS="$(codesign -d --entitlements :- "$ENGINE" 2>/dev/null || true)"
  for entitlement in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation; do
    [[ "$BINARY_ENTITLEMENTS" == *"$entitlement"* ]] || {
      echo "syntila is missing hardened-runtime entitlement: $entitlement" >&2
      exit 1
    }
    [[ "$ENGINE_ENTITLEMENTS" == *"$entitlement"* ]] || {
      echo "The Worker Engine is missing hardened-runtime entitlement: $entitlement" >&2
      exit 1
    }
  done

  [[ "$(identifier "$BINARY")" == "syntila" ]] || {
    echo "syntila has an unexpected designated identifier: $(identifier "$BINARY")." >&2
    exit 1
  }
  [[ "$(identifier "$ENGINE")" == "syntila-agent" ]] || {
    echo "The Worker Engine has an unexpected designated identifier: $(identifier "$ENGINE")." >&2
    exit 1
  }

  # Apple-signed bundles must have one signing team across the binary and the
  # Engine. Ad-hoc signatures have no team identifier and are allowed for
  # development builds.
  BINARY_TEAM_ID="$(team_id "$BINARY")"
  ENGINE_TEAM_ID="$(team_id "$ENGINE")"
  if [[ -n "$BINARY_TEAM_ID" || -n "$ENGINE_TEAM_ID" ]]; then
    codesign --verify --strict --verbose=2 \
      --test-requirement '=anchor apple generic' "$BINARY"
    codesign --verify --strict --verbose=2 \
      --test-requirement '=anchor apple generic' "$ENGINE"
    [[ -n "$BINARY_TEAM_ID" && "$BINARY_TEAM_ID" == "$ENGINE_TEAM_ID" ]] || {
      echo "syntila and the Worker Engine are not signed by the same team." >&2
      exit 1
    }
  fi
fi
echo "Workspace bundle is structurally valid: $BUNDLE"
