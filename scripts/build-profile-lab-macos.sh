#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_LAB_DIR="$ROOT/apps/profile_lab"
DIST_DIR="$ROOT/dist/conclave-profile-lab/macos"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Conclave Profile Lab macOS builds must run on macOS." >&2
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
SIGN_APP="0"

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
      CONCLAVE_PROFILE_LAB_VERSION="$2"
      shift 2
      ;;
    --unsigned)
      SIGN_APP="0"
      shift
      ;;
    --sign)
      SIGN_APP="1"
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
      echo "Builds the Conclave Profile Lab desktop application for macOS."
      echo "Run scripts/test-profile-lab-macos.sh separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --release          Build in release mode (default)"
      echo "  --debug            Build in debug mode"
      echo "  --version, -v VER  Override Profile Lab version"
      echo "  --unsigned         Skip Developer ID signing and notarization (default)"
      echo "  --sign IDENTITY    Developer ID signing identity"
      echo "  --open, -o         Open the built application bundle after build"
      echo "  --help, -h         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  CONCLAVE_PROFILE_LAB_VERSION         Profile Lab version override"
      echo "  CONCLAVE_RELEASE_TRUST_KEYS_JSON     Public Ed25519 Profile trust roots"
      echo "  CONCLAVE_MACOS_SIGN_IDENTITY         Signing identity"
      echo "  CONCLAVE_MACOS_NOTARY_PROFILE        Keychain profile for notarization"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

VERSION="${CONCLAVE_PROFILE_LAB_VERSION:-$(awk '/^version:/ {print $2; exit}' "$PROFILE_LAB_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Conclave Profile Lab version." >&2
  exit 1
fi

echo "Building Conclave Profile Lab $VERSION for macOS (mode: $MODE)"
cd "$PROFILE_LAB_DIR"
flutter clean
flutter pub get
bash "$ROOT/scripts/build-cli-worker-engine.sh"

if [[ "$MODE" == "debug" ]]; then
  flutter build macos --debug \
    --dart-define=CONCLAVE_PROFILE_LAB_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
  APP="$PROFILE_LAB_DIR/build/macos/Build/Products/Debug/Conclave Profile Lab.app"
else
  flutter build macos --release \
    --dart-define=CONCLAVE_PROFILE_LAB_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="${CONCLAVE_RELEASE_TRUST_KEYS_JSON:-{}}"
  APP="$PROFILE_LAB_DIR/build/macos/Build/Products/Release/Conclave Profile Lab.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

if [[ "$SIGN_APP" == "1" && -n "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with configured Developer ID identity"
  codesign --force --deep --options runtime --timestamp \
    --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "CONCLAVE_MACOS_SIGN_IDENTITY is not set; producing an unsigned development artifact."
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/Conclave-Profile-Lab-$VERSION-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SIGN_APP" == "1" && -n "${CONCLAVE_MACOS_NOTARY_PROFILE:-}" ]]; then
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
