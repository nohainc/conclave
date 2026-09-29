#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="$ROOT/apps/host"
DIST_DIR="$ROOT/dist/conclave-workspace/macos"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Conclave Workspace macOS builds must run on macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}
command -v ditto >/dev/null 2>&1 || {
  echo "ditto is required on macOS." >&2
  exit 1
}

MODE="release"
OPEN_APP="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      MODE="debug"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --version|-v)
      CONCLAVE_WORKSPACE_VERSION="$2"
      shift 2
      ;;
    --sign)
      CONCLAVE_MACOS_SIGN_IDENTITY="$2"
      shift 2
      ;;
    --open|-o)
      OPEN_APP="1"
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Builds the Conclave Workspace desktop application for macOS."
      echo "Run scripts/test-workspace-macos.sh separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --release          Build in release mode (default)"
      echo "  --debug            Build in debug mode"
      echo "  --version, -v VER  Override workspace version"
      echo "  --sign IDENTITY    Developer ID signing identity"
      echo "  --open, -o         Open the built application bundle after build"
      echo "  --help, -h         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  CONCLAVE_WORKSPACE_VERSION           Workspace version override"
      echo "  CONCLAVE_MACOS_SIGN_IDENTITY         Signing identity"
      echo "  CONCLAVE_MACOS_NOTARY_PROFILE        Keychain profile for notarization"
      echo "  CONCLAVE_RELEASE_TRUST_KEYS_JSON     Public Ed25519 trust roots"
      echo "  CONCLAVE_ADAPTER_ED25519_SEED        Adapter package signing seed"
      echo "  CONCLAVE_ADAPTER_SIGNING_KEY_ID      Adapter package signing key ID"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

VERSION="${CONCLAVE_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$HOST_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Conclave Workspace version." >&2
  exit 1
fi

echo "Building Conclave Workspace $VERSION for macOS (mode: $MODE)"
cd "$HOST_DIR"
flutter clean
flutter pub get

if [[ -z "${CONCLAVE_ADAPTER_ED25519_SEED:-}" || -z "${CONCLAVE_ADAPTER_SIGNING_KEY_ID:-}" ]]; then
  echo "Bundled first-party adapters require CONCLAVE_ADAPTER_ED25519_SEED and CONCLAVE_ADAPTER_SIGNING_KEY_ID." >&2
  exit 1
fi

ADAPTER_ASSET_DIR="$HOST_DIR/assets/adapters"
mkdir -p "$ADAPTER_ASSET_DIR"
rm -f "$ADAPTER_ASSET_DIR/codex.tgz" "$ADAPTER_ASSET_DIR/codex.json" \
  "$ADAPTER_ASSET_DIR/antigravity.tgz" "$ADAPTER_ASSET_DIR/antigravity.json"

for ADAPTER_ID in codex antigravity; do
  ARCHIVE="$ADAPTER_ASSET_DIR/$ADAPTER_ID.tgz"
  MANIFEST="$ARCHIVE.manifest.json"
  CONCLAVE_WORKER_TRUST_PUBLISHER=conclave \
  CONCLAVE_RELEASE_SIGNING_SEED="$CONCLAVE_ADAPTER_ED25519_SEED" \
  CONCLAVE_RELEASE_SIGNING_KEY_ID="$CONCLAVE_ADAPTER_SIGNING_KEY_ID" \
    dart run bin/package_v7_adapter.dart \
      --source "../../packages/worker-manifest/adapters/$ADAPTER_ID" \
      --output "$ARCHIVE" --channel stable
  dart run \
    -DCONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}" \
    bin/verify_v7_adapter_release.dart "$ARCHIVE" "$MANIFEST"
  cp "$MANIFEST" "$ADAPTER_ASSET_DIR/$ADAPTER_ID.json"
  rm -f "$MANIFEST"
done

if [[ "$MODE" == "debug" ]]; then
  flutter build macos --debug \
    --dart-define=CONCLAVE_WORKSPACE_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
  APP="$HOST_DIR/build/macos/Build/Products/Debug/Conclave Workspace.app"
else
  flutter build macos --release \
    --dart-define=CONCLAVE_WORKSPACE_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
  APP="$HOST_DIR/build/macos/Build/Products/Release/Conclave Workspace.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

if [[ -n "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with configured Developer ID identity"
  codesign --force --deep --options runtime --timestamp \
    --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "CONCLAVE_MACOS_SIGN_IDENTITY is not set; producing an unsigned development artifact."
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/Conclave-Workspace-$VERSION-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n "${CONCLAVE_MACOS_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
    echo "Notarization requires CONCLAVE_MACOS_SIGN_IDENTITY." >&2
    exit 1
  fi
  echo "Submitting to Apple notarization"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$CONCLAVE_MACOS_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "Built app bundle: $APP"
echo "Built distribution archive: $ZIP"

if [[ "$OPEN_APP" == "1" ]]; then
  echo "Opening $APP..."
  open "$APP"
fi
