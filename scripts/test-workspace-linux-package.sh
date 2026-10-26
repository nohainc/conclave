#!/usr/bin/env bash
# Real apt install/upgrade/remove and packaged foreground service smoke on Linux.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'This test needs Linux.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64) DEB_ARCH=amd64 ;; arm64) DEB_ARCH=arm64 ;; *) exit 2 ;; esac
VERSION="${CONCLAVE_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
PACKAGE="$ROOT/dist/conclave-workspace/deb/conclave-workspace_${VERSION}_${DEB_ARCH}.deb"
TEST_ROOT="$(mktemp -d)"
chmod 755 "$TEST_ROOT"
service_pid=''
cleanup() {
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fi
  sudo apt-get remove -y conclave-workspace >/dev/null 2>&1 || true
  gpgconf --kill gpg-agent || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export GNUPGHOME="$TEST_ROOT/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Conclave package test <test@example.invalid>' ed25519 sign 1d
KEY="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr" {print $10; exit}')"
CONCLAVE_WORKSPACE_VERSION=0.0.1~test bash "$ROOT/scripts/package-workspace-linux.sh" "$ARCH"
OLD="$ROOT/dist/conclave-workspace/deb/conclave-workspace_0.0.1~test_${DEB_ARCH}.deb"
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEST_ROOT/repo" --signing-key "$KEY" "$OLD"
cat > "$TEST_ROOT/conclave.sources" <<SOURCES
Types: deb
URIs: file:$TEST_ROOT/repo
Suites: stable
Components: main
Architectures: $DEB_ARCH
Signed-By: $TEST_ROOT/repo/conclave-archive-keyring.gpg
SOURCES
APT_ARGS=(-o "Dir::Etc::sourcelist=$TEST_ROOT/conclave.sources" -o 'Dir::Etc::sourceparts=-')
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install -y conclave-workspace=0.0.1~test
STATE="$TEST_ROOT/state"
CONCLAVE_WORKSPACE_SECRET_STORE='file' conclave-service --data-dir "$STATE" --work-root "$TEST_ROOT/work" --once
identity="$(cat "$STATE/installation-id")"
mkdir -p "$STATE/sessions" "$TEST_ROOT/work"
printf 'keep session\n' > "$STATE/sessions/preserve-test"
printf 'keep user work\n' > "$TEST_ROOT/work/preserve-test"
python3 "$ROOT/scripts/release/build-apt-repository.py" --output "$TEST_ROOT/repo" --signing-key "$KEY" "$PACKAGE"
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install --only-upgrade -y conclave-workspace
[[ "$(dpkg-query --show --showformat='${Version}' conclave-workspace)" == "$VERSION" ]]
[[ "$(cat "$STATE/installation-id")" == "$identity" ]]
grep -qx 'keep session' "$STATE/sessions/preserve-test"
grep -qx 'keep user work' "$TEST_ROOT/work/preserve-test"
CONCLAVE_WORKSPACE_SECRET_STORE='file' conclave-service --data-dir "$STATE" --work-root "$TEST_ROOT/work" > "$TEST_ROOT/service.log" 2>&1 &
service_pid=$!
ready=0
for _ in $(seq 1 60); do
  if conclave-workspace --data-dir "$STATE" --json health > "$TEST_ROOT/health.json" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then cat "$TEST_ROOT/service.log"; exit 1; fi
python3 - "$TEST_ROOT/health.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['healthy'] is True
PY
conclave-workspace --data-dir "$STATE" --json version > "$TEST_ROOT/version.json"
python3 - "$TEST_ROOT/version.json" "$VERSION" <<'PYVERSION'
import json, sys
assert json.load(open(sys.argv[1]))['version'] == sys.argv[2]
PYVERSION
conclave-workspace --data-dir "$STATE" status
conclave-workspace --data-dir "$STATE" workers
kill "$service_pid"
wait "$service_pid"
service_pid=''
sudo apt-get remove -y conclave-workspace
[[ "$(cat "$STATE/installation-id")" == "$identity" ]]
grep -qx 'keep session' "$STATE/sessions/preserve-test"
grep -qx 'keep user work' "$TEST_ROOT/work/preserve-test"
echo 'APT install, upgrade, IPC, graceful stop and removal preserved user state.'
