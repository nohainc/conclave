#!/usr/bin/env bash
# Real apt install/upgrade/remove and packaged foreground service smoke on Linux.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'This test needs Linux.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64) DEB_ARCH=amd64 ;; arm64) DEB_ARCH=arm64 ;; *) exit 2 ;; esac
VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
PACKAGE="$ROOT/dist/syntila-workspace/deb/syntila-workspace_${VERSION}_${DEB_ARCH}.deb"
TEST_ROOT="$(mktemp -d)"
chmod 755 "$TEST_ROOT"
service_pid=''
cleanup() {
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fi
  sudo apt-get remove -y syntila-workspace >/dev/null 2>&1 || true
  gpgconf --kill gpg-agent || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export GNUPGHOME="$TEST_ROOT/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Syntila package test <test@example.invalid>' ed25519 sign 1d
KEY="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr" {print $10; exit}')"
# Deliberately label the same fixture payload as an older package for upgrade
# acceptance; production packaging otherwise requires a matching build manifest.
node "$ROOT/scripts/workspace-build-manifest.mjs" record "$ROOT/dist/syntila-workspace/linux-$ARCH" '0.0.1~test'
SYNTILA_WORKSPACE_VERSION=0.0.1~test bash "$ROOT/scripts/package-workspace-linux.sh" "$ARCH"
node "$ROOT/scripts/workspace-build-manifest.mjs" record "$ROOT/dist/syntila-workspace/linux-$ARCH" "$VERSION"
OLD="$ROOT/dist/syntila-workspace/deb/syntila-workspace_0.0.1~test_${DEB_ARCH}.deb"
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEST_ROOT/repo" --signing-key "$KEY" "$OLD"
cat > "$TEST_ROOT/syntila.sources" <<SOURCES
Types: deb
URIs: file:$TEST_ROOT/repo
Suites: stable
Components: main
Architectures: $DEB_ARCH
Signed-By: $TEST_ROOT/repo/syntila-archive-keyring.gpg
SOURCES
APT_ARGS=(-o "Dir::Etc::sourcelist=$TEST_ROOT/syntila.sources" -o 'Dir::Etc::sourceparts=-')
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install -y syntila-workspace=0.0.1~test
STATE="$TEST_ROOT/state"
mkdir -p "$TEST_ROOT/home"
HOME="$TEST_ROOT/home" SYNTILA_WORKSPACE_SECRET_STORE='file' syntila-workspace run --data-dir "$STATE" --once
identity="$(cat "$STATE/installation-id")"
mkdir -p "$STATE/sessions" "$TEST_ROOT/home/Documents/Syntila"
printf 'keep session\n' > "$STATE/sessions/preserve-test"
printf 'keep user work\n' > "$TEST_ROOT/home/Documents/Syntila/preserve-test"
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEST_ROOT/repo" --signing-key "$KEY" "$PACKAGE"
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install --only-upgrade -y syntila-workspace
[[ "$(dpkg-query --show --showformat='${Version}' syntila-workspace)" == "$VERSION" ]]
[[ "$(cat "$STATE/installation-id")" == "$identity" ]]
grep -qx 'keep session' "$STATE/sessions/preserve-test"
grep -qx 'keep user work' "$TEST_ROOT/home/Documents/Syntila/preserve-test"
HOME="$TEST_ROOT/home" SYNTILA_WORKSPACE_SECRET_STORE='file' syntila-workspace run --data-dir "$STATE" > "$TEST_ROOT/service.log" 2>&1 &
service_pid=$!
ready=0
for _ in $(seq 1 60); do
  if syntila-workspace --data-dir "$STATE" --json status > "$TEST_ROOT/health.json" 2>/dev/null &&
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("service", {}).get("serviceHealthy") is True else 1)' "$TEST_ROOT/health.json"; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then cat "$TEST_ROOT/service.log"; exit 1; fi
python3 - "$TEST_ROOT/health.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['service']['serviceHealthy'] is True
PY
syntila-workspace --data-dir "$STATE" --json version > "$TEST_ROOT/version.json"
python3 - "$TEST_ROOT/version.json" "$VERSION" <<'PYVERSION'
import json, sys
assert json.load(open(sys.argv[1]))['version'] == sys.argv[2]
PYVERSION
syntila-workspace --data-dir "$STATE" status
syntila-workspace --data-dir "$STATE" workers
python3 - <<'PYENGINE'
import subprocess
result = subprocess.run(['/usr/lib/syntila-workspace/assets/engines/syntila-agent'], capture_output=True, text=True, timeout=10)
assert result.returncode == 64, result
assert 'Engine options are incomplete or invalid' in result.stderr
PYENGINE
kill "$service_pid"
wait "$service_pid"
service_pid=''
sudo apt-get remove -y syntila-workspace
[[ "$(cat "$STATE/installation-id")" == "$identity" ]]
grep -qx 'keep session' "$STATE/sessions/preserve-test"
grep -qx 'keep user work' "$TEST_ROOT/home/Documents/Syntila/preserve-test"
echo 'APT install, upgrade, IPC, graceful stop and removal preserved user state.'
