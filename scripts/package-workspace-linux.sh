#!/usr/bin/env bash
# Packages an already built headless bundle. Works on Linux or macOS with dpkg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64) DEB_ARCH=amd64; ELF_MACHINE=62 ;; arm64) DEB_ARCH=arm64; ELF_MACHINE=183 ;; *) echo "Usage: $0 [x64|arm64]" >&2; exit 2 ;; esac
VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
# A +build suffix is legal in Debian versions; refuse control/path characters.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+~.-][A-Za-z0-9.+~-]+)?$ ]] || { echo "Invalid package version: $VERSION" >&2; exit 2; }
command -v dpkg-deb >/dev/null || { echo "Install dpkg (apt-get install dpkg-dev; brew install dpkg)." >&2; exit 1; }
BUNDLE="$ROOT/dist/syntila/linux-$ARCH"
node "$ROOT/scripts/workspace-build-manifest.mjs" verify "$BUNDLE" "$VERSION"
# Verify ELF target rather than accidentally packaging this Mac's executables.
python3 - "$BUNDLE" "$ELF_MACHINE" <<'PY'
import pathlib, struct, sys
root, machine = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for name in ('syntila', 'assets/engines/syntila-agent'):
    path = root / name
    header = path.read_bytes()[:20]
    if header[:6] != b'\x7fELF\x02\x01' or struct.unpack('<H', header[18:20])[0] != machine:
        raise SystemExit(f'Not a Linux executable of the requested architecture: {path}')
PY
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/usr/lib/syntila"
mkdir -p "$STAGE/DEBIAN" "$PAYLOAD/assets/engines" "$STAGE/usr/bin" "$STAGE/usr/share/doc/syntila"
install -m 755 "$BUNDLE/syntila" "$PAYLOAD/"
install -m 755 "$BUNDLE/assets/engines/syntila-agent" "$PAYLOAD/assets/engines/"
# Symlinks keep Platform.resolvedExecutable beside the service and Engine.
ln -s ../lib/syntila/syntila "$STAGE/usr/bin/syntila"
install -m 644 "$ROOT/docs/operations/WORKSPACE_LINUX.md" "$STAGE/usr/share/doc/syntila/README.md"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: syntila
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Syntila <support@conclaveax.com>
Section: devel
Priority: optional
Depends: libc6 (>= 2.31), libgcc-s1, libstdc++6, ca-certificates
Recommends: systemd, dbus-user-session
Suggests: libsecret-tools
Homepage: https://conclaveax.com
Description: Headless Syntila Workspace service and management CLI
 Includes the generic CLI Worker Engine. Runs as the user who owns provider
 CLI logins. No desktop environment is required. Provider CLIs are separate.
CONTROL
# No root maintainer scripts: installation/removal never reads or deletes user
# state, starts a root service, or interrupts running user assignments.
chmod 755 "$STAGE" "$STAGE/DEBIAN"
OUTPUT="$ROOT/dist/syntila/deb"
mkdir -p "$OUTPUT"
dpkg-deb --build --root-owner-group -Zgzip "$STAGE" "$OUTPUT/syntila_${VERSION}_${DEB_ARCH}.deb"
