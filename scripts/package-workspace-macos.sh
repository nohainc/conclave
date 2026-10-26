#!/usr/bin/env bash
set -euo pipefail

# Packages a built Conclave Workspace.app into macOS installers:
#   - a drag-to-Applications .dmg
#   - an installer .pkg that installs into /Applications
#
# The app bundle is self-contained: it embeds the headless Workspace Service
# (Contents/Helpers/workspace), the generic CLI Worker Engine
# (Contents/Helpers/assets/engines/conclave_cli_worker_engine), and the
# SMAppService LaunchAgent manifest (Contents/Library/LaunchAgents). The
# installer does not register or start the service; Workspace.app does that
# through SMAppService on first launch, which keeps registration and existing
# Application Support state (installation ID, credentials, Work Root, sessions)
# under the app's control across upgrades.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ENV="production"
APP=""
BUILD="0"
FORMATS="dmg,pkg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) TARGET_ENV="local"; shift ;;
    --prod|--production) TARGET_ENV="production"; shift ;;
    --app) APP="$2"; shift 2 ;;
    --build) BUILD="1"; shift ;;
    --format) FORMATS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Packages Conclave Workspace.app (with embedded service and Engine)"
      echo "into a .dmg and/or .pkg installer."
      echo ""
      echo "Options:"
      echo "  --build            Run build-workspace-macos.sh first"
      echo "  --local | --prod   Which built variant to package (default prod)"
      echo "  --app PATH         Package this app bundle instead of the dist copy"
      echo "  --format LIST      dmg, pkg, or dmg,pkg (default dmg,pkg)"
      echo ""
      echo "Environment variables:"
      echo "  CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY  'Developer ID Installer: ...' for the .pkg"
      echo "  CONCLAVE_MACOS_SIGN_IDENTITY            Identity used to sign the .dmg"
      echo "  CONCLAVE_MACOS_NOTARY_PROFILE           notarytool keychain profile"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS installers must be built on macOS." >&2
  exit 1
fi

DIST_DIR="$ROOT/dist/conclave-workspace/macos"
APP_NAME="Conclave Workspace"
BUNDLE_ID="com.conclaveax.workspace"
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/conclave-workspace/macos-local"
  APP_NAME="Conclave Workspace Local"
  BUNDLE_ID="com.conclaveax.workspace.local"
fi

if [[ "$BUILD" == "1" ]]; then
  bash "$ROOT/scripts/build-workspace-macos.sh" "--$TARGET_ENV"
fi

APP="${APP:-$DIST_DIR/$APP_NAME.app}"
if [[ ! -d "$APP" ]]; then
  echo "App bundle not found: $APP" >&2
  echo "Build it first: pnpm workspace:build:macos (or pass --build)." >&2
  exit 1
fi

# Refuse to ship a bundle without the embedded service, Engine, and agent plist.
bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SUFFIX=""
[[ "$TARGET_ENV" == "local" ]] && SUFFIX="-local"
BASENAME="Conclave-Workspace-$VERSION-macos$SUFFIX"

notarize() {
  local artifact="$1"
  [[ -n "${CONCLAVE_MACOS_NOTARY_PROFILE:-}" ]] || return 0
  echo "Notarizing $(basename "$artifact")"
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$CONCLAVE_MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$artifact"
}

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [[ ",$FORMATS," == *",dmg,"* ]]; then
  DMG="$DIST_DIR/$BASENAME.dmg"
  mkdir -p "$STAGING/dmg"
  ditto "$APP" "$STAGING/dmg/$(basename "$APP")"
  ln -s /Applications "$STAGING/dmg/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING/dmg" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  if [[ -n "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" "$DMG"
  fi
  notarize "$DMG"
  echo "Built disk image: $DMG"
fi

if [[ ",$FORMATS," == *",pkg,"* ]]; then
  PKG="$DIST_DIR/$BASENAME.pkg"
  COMPONENT="$STAGING/component.pkg"
  mkdir -p "$STAGING/root"
  ditto "$APP" "$STAGING/root/$(basename "$APP")"
  xattr -crs "$STAGING/root"
  pkgbuild --analyze --root "$STAGING/root" "$STAGING/components.plist" >/dev/null
  # Always install into /Applications, never into a relocated older copy.
  /usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$STAGING/components.plist"
  COPYFILE_DISABLE=1 pkgbuild --root "$STAGING/root" \
    --component-plist "$STAGING/components.plist" \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$VERSION" \
    --install-location /Applications \
    "$COMPONENT" >/dev/null
  SIGN_ARGS=()
  if [[ -n "${CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--sign "$CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY" --timestamp)
  else
    echo "CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY is not set; the .pkg is unsigned."
  fi
  rm -f "$PKG"
  productbuild --package "$COMPONENT" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG" >/dev/null
  notarize "$PKG"
  echo "Built installer package: $PKG"
fi
