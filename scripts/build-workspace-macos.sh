#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
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
PREPARED="0"
DEFAULT_CONCLAVE_MACOS_SIGN_IDENTITY='Apple Development: vitalii@nohainc.com (7X62W6499P)'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepared)
      PREPARED="1"
      shift
      ;;
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
      echo "  --prepared         Reuse dependencies and Engine; skip clean (CI only)"
      echo "  --release          Build in release mode (default)"
      echo "  --debug            Build in debug mode"
      echo "  --version, -v VER  Override workspace version"
      echo "  --sign IDENTITY    Apple signing identity"
      echo "  --open, -o         Open the built application bundle after build"
      echo "  --help, -h         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  CONCLAVE_WORKSPACE_VERSION           Workspace version override"
      echo "  CONCLAVE_MACOS_SIGN_IDENTITY         Signing identity override"
      echo "  CONCLAVE_MACOS_NOTARY_PROFILE        Keychain profile for notarization"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# A normal invocation is a signed release build. Keep the identity overridable
# for another certificate, CI, or a Developer ID distribution build.
if [[ "$MODE" == "release" && -z "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  CONCLAVE_MACOS_SIGN_IDENTITY="$DEFAULT_CONCLAVE_MACOS_SIGN_IDENTITY"
fi

if [[ "$MODE" == "release" && -z "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Release Workspace builds require an Apple signing identity for the SMAppService LaunchAgent." >&2
  echo "Use --sign 'Apple Development: ...' or 'Developer ID Application: ...' (or CONCLAVE_MACOS_SIGN_IDENTITY)." >&2
  echo "For UI inspection only, use --debug; its ad-hoc service cannot start through launchd." >&2
  exit 1
fi
if [[ -n "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  if ! security find-identity -v -p codesigning | /usr/bin/grep -F -- "$CONCLAVE_MACOS_SIGN_IDENTITY" >/dev/null; then
    echo "The requested signing identity is not available as a valid code-signing identity in Keychain." >&2
    exit 1
  fi
fi

VERSION="${CONCLAVE_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Conclave Workspace version." >&2
  exit 1
fi

PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-profile-trust.mjs")"
echo "Building Conclave Workspace $VERSION for macOS (mode: $MODE)"
cd "$WORKSPACE_DIR"
if [[ "$PREPARED" == "1" ]]; then
  [[ -f .dart_tool/package_config.json && -x assets/engines/conclave_cli_worker_engine ]] || {
    echo "Prepared build requires resolved app dependencies and a freshly built Engine." >&2
    exit 1
  }
else
  flutter clean
  flutter pub get
  bash "$ROOT/scripts/build-cli-worker-engine.sh"
fi

if [[ "$MODE" == "debug" ]]; then
  flutter build macos --debug \
    --dart-define=CONCLAVE_WORKSPACE_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="$PUBLIC_RELEASE_ROOTS"
  APP="$WORKSPACE_DIR/build/macos/Build/Products/Debug/Conclave Workspace.app"
else
  flutter build macos --release \
    --dart-define=CONCLAVE_WORKSPACE_VERSION="$VERSION" \
    --dart-define=CONCLAVE_RELEASE_TRUST_KEYS_JSON="$PUBLIC_RELEASE_ROOTS"
  APP="$WORKSPACE_DIR/build/macos/Build/Products/Release/Conclave Workspace.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

# Embed the standalone Dart runtime after Flutter assembles the UI app. The
# helper loads its Worker Engine from its adjacent assets directory, so neither
# process depends on the current working directory or a shell profile.
FLUTTER_EXE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v flutter)")"
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_EXE")/.." && pwd)"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [[ ! -x "$DART" ]]; then
  command -v dart >/dev/null 2>&1 || {
    echo "Dart is required to compile the Workspace service." >&2
    exit 1
  }
  DART="$(command -v dart)"
fi
HELPERS_DIR="$APP/Contents/Helpers"
LAUNCH_AGENTS_DIR="$APP/Contents/Library/LaunchAgents"
mkdir -p "$HELPERS_DIR/assets/engines" "$LAUNCH_AGENTS_DIR"
"$DART" compile exe \
  --define="CONCLAVE_WORKSPACE_VERSION=$VERSION" \
  --define="CONCLAVE_RELEASE_TRUST_KEYS_JSON=$PUBLIC_RELEASE_ROOTS" \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  "$WORKSPACE_DIR/bin/conclave_workspace_service.dart" \
  -o "$HELPERS_DIR/conclave-service"
ENGINE="$WORKSPACE_DIR/assets/engines/conclave_cli_worker_engine"
if [[ ! -x "$ENGINE" ]]; then
  echo "The generic CLI Worker Engine is missing: $ENGINE" >&2
  exit 1
fi
cp "$ENGINE" "$HELPERS_DIR/assets/engines/conclave_cli_worker_engine"
chmod 755 "$HELPERS_DIR/conclave-service" \
  "$HELPERS_DIR/assets/engines/conclave_cli_worker_engine"
cp "$WORKSPACE_DIR/macos/Runner/LaunchAgents/com.conclaveax.workspace.service.plist" \
  "$LAUNCH_AGENTS_DIR/com.conclaveax.workspace.service.plist"

if [[ -n "${CONCLAVE_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with configured Apple identity"
  if [[ "$MODE" == "debug" ]]; then
    APP_ENTITLEMENTS="$WORKSPACE_DIR/macos/Runner/DebugProfile.entitlements"
  else
    APP_ENTITLEMENTS="$WORKSPACE_DIR/macos/Runner/Release.entitlements"
  fi

  # Flutter initially signs its embedded frameworks with the build-time
  # identity. Re-sign every embedded framework with the same identity as the
  # application before sealing the app, otherwise dyld rejects the framework
  # as a non-platform mapping at process launch.
  while IFS= read -r -d '' framework; do
    codesign --force --options runtime --timestamp \
      --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" "$framework"
  done < <(find "$APP/Contents/Frameworks" -type d -name '*.framework' \
    -prune -print0)

  # Sign the standalone executables with their own hardened-runtime
  # entitlements first. Do not use --deep for the application after this:
  # recursive signing can replace these helper entitlements and leave a
  # launchd job that passes a shallow signature check but exits with
  # OS_REASON_CODESIGNING.
  codesign --force --options runtime --timestamp \
    --entitlements "$WORKSPACE_DIR/macos/Runner/WorkspaceHelper.entitlements" \
    --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" \
    "$HELPERS_DIR/assets/engines/conclave_cli_worker_engine"
  codesign --force --options runtime --timestamp \
    --entitlements "$WORKSPACE_DIR/macos/Runner/WorkspaceHelper.entitlements" \
    --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" \
    "$HELPERS_DIR/conclave-service"

  # The Flutter build has already signed the embedded Flutter frameworks. Seal
  # only the application bundle so the helper signatures above remain intact.
  codesign --force --options runtime --timestamp \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$CONCLAVE_MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 \
    "$HELPERS_DIR/conclave-service"
  codesign --verify --strict --verbose=2 \
    "$HELPERS_DIR/assets/engines/conclave_cli_worker_engine"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  if [[ "$MODE" == "debug" ]]; then
    echo "No Apple signing identity was supplied; this is a UI-only debug bundle."
    echo "The Workspace Service controls will explain that launchd execution is unavailable."
  else
    echo "CONCLAVE_MACOS_SIGN_IDENTITY is not set; sealing the development bundle with ad-hoc signatures."
  fi
  codesign --force --sign - \
    "$HELPERS_DIR/assets/engines/conclave_cli_worker_engine"
  codesign --force --sign - "$HELPERS_DIR/conclave-service"
  codesign --force --deep --sign - "$APP"
fi

bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$APP"

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
