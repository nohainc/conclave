#!/usr/bin/env bash
set -euo pipefail

# Packages a built macOS Workspace bundle (conclave-workspace, the `workspace`
# alias and the CLI Worker Engine) into an installer .pkg that installs under
# /usr/local/lib and links the commands into /usr/local/bin. The installer does
# not register or start the service; run `conclave-workspace service install`
# afterwards. Existing Application Support state (installation ID, credentials,
# Work Root, sessions) is never touched.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ENV="production"
BUNDLE=""
BUILD="0"
FORMATS="pkg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) TARGET_ENV="local"; shift ;;
    --prod|--production) TARGET_ENV="production"; shift ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --build) BUILD="1"; shift ;;
    --format) FORMATS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Packages the built Workspace bundle into an installer .pkg."
      echo ""
      echo "Options:"
      echo "  --build            Run build-workspace-macos.sh first"
      echo "  --local | --prod   Which built variant to package (default prod)"
      echo "  --bundle PATH      Package this bundle directory instead of the dist copy"
      echo "  --format pkg       Only pkg is supported (the zip comes from the build)"
      echo ""
      echo "Environment variables:"
      echo "  CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY  'Developer ID Installer: ...' for the .pkg"
      echo "  CONCLAVE_MACOS_NOTARY_PROFILE           notarytool keychain profile"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$FORMATS" != "pkg" ]]; then
  echo "Only --format pkg is supported; the zip archive is produced by build-workspace-macos.sh." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS installers must be built on macOS." >&2
  exit 1
fi

DIST_DIR="$ROOT/dist/conclave-workspace/macos"
BUNDLE_NAME="conclave-workspace"
PKG_ID="com.conclaveax.workspace.pkg"
SUFFIX=""
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/conclave-workspace/macos-local"
  BUNDLE_NAME="conclave-workspace-local"
  PKG_ID="com.conclaveax.workspace.local.pkg"
  SUFFIX="-local"
fi

if [[ "$BUILD" == "1" ]]; then
  bash "$ROOT/scripts/build-workspace-macos.sh" "--$TARGET_ENV"
fi

BUNDLE="${BUNDLE:-$DIST_DIR/$BUNDLE_NAME}"
if [[ ! -d "$BUNDLE" ]]; then
  echo "Bundle not found: $BUNDLE" >&2
  echo "Build it first: pnpm workspace:build:macos (or pass --build)." >&2
  exit 1
fi

# Refuse to ship a bundle without the service binary, alias and Engine.
bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$BUNDLE"

VERSION="${CONCLAVE_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
PKG="$DIST_DIR/Syntila-Workspace-$VERSION-macos$SUFFIX.pkg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
LIB="$STAGING/root/usr/local/lib/$BUNDLE_NAME"
BIN="$STAGING/root/usr/local/bin"
mkdir -p "$LIB" "$BIN"
ditto "$BUNDLE" "$LIB"
if [[ "$TARGET_ENV" == "local" ]]; then
  ln -s "../lib/$BUNDLE_NAME/conclave-workspace" "$BIN/conclave-workspace-local"
else
  ln -s "../lib/$BUNDLE_NAME/conclave-workspace" "$BIN/conclave-workspace"
fi
xattr -crs "$STAGING/root"

COMPONENT="$STAGING/component.pkg"
COPYFILE_DISABLE=1 pkgbuild --root "$STAGING/root" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location / \
  "$COMPONENT" >/dev/null
SIGN_ARGS=()
if [[ -n "${CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--sign "$CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY" --timestamp)
else
  echo "CONCLAVE_MACOS_INSTALLER_SIGN_IDENTITY is not set; the .pkg is unsigned."
fi
rm -f "$PKG"
productbuild --package "$COMPONENT" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG" >/dev/null

if [[ -n "${CONCLAVE_MACOS_NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing $(basename "$PKG")"
  xcrun notarytool submit "$PKG" \
    --keychain-profile "$CONCLAVE_MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
echo "Built installer package: $PKG"
