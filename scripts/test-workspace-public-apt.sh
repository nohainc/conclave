#!/usr/bin/env bash
# Acceptance against the public HTTPS repository, on a fresh Ubuntu runner.
set -euo pipefail
: "${CONCLAVE_APT_URL:?}" "${CONCLAVE_APT_SIGNING_FINGERPRINT:?}" "${CONCLAVE_WORKSPACE_VERSION:?}"
[[ "$CONCLAVE_APT_URL" == https://* ]] || { echo 'Public repository must use HTTPS.' >&2; exit 1; }
if dpkg-query -W -f='${Status}' conclave-workspace 2>/dev/null | grep -q 'install ok installed'; then
  echo 'Use a fresh test host; Conclave Workspace is already installed.' >&2
  exit 1
fi
TEMP="$(mktemp -d /tmp/conclave-public-apt.XXXXXX)"
chmod 755 "$TEMP"
service_pid=''
installed=0
cleanup() {
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fi
  if [[ "$installed" == 1 ]]; then sudo apt-get remove -y conclave-workspace >/dev/null 2>&1 || true; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT
curl --fail --silent --show-error --location --retry 12 --retry-all-errors --retry-delay 5 \
  "${CONCLAVE_APT_URL%/}/conclave-archive-keyring.gpg" -o "$TEMP/keyring.gpg"
FINGERPRINT="$(gpg --show-keys --with-colons "$TEMP/keyring.gpg" | awk -F: '$1=="fpr" {print $10; exit}')"
[[ "$FINGERPRINT" == "$CONCLAVE_APT_SIGNING_FINGERPRINT" ]] || { echo 'Unexpected public signing key.' >&2; exit 1; }
curl --fail --silent --show-error --location --retry 12 --retry-all-errors --retry-delay 5 \
  "${CONCLAVE_APT_URL%/}/dists/stable/InRelease" -o "$TEMP/InRelease"
gpgv --keyring "$TEMP/keyring.gpg" "$TEMP/InRelease"
cat > "$TEMP/conclave.sources" <<SOURCES
Types: deb
URIs: $CONCLAVE_APT_URL
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: $TEMP/keyring.gpg
SOURCES
APT_ARGS=(-o "Dir::Etc::sourcelist=$TEMP/conclave.sources" -o 'Dir::Etc::sourceparts=-' -o Acquire::Retries=5)
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install --no-install-recommends -y "conclave-workspace=$CONCLAVE_WORKSPACE_VERSION"
installed=1
CONCLAVE_WORKSPACE_SECRET_STORE='file' conclave-service --data-dir "$TEMP/state" --work-root "$TEMP/work" > "$TEMP/service.log" 2>&1 &
service_pid=$!
ready=0
for _ in $(seq 1 60); do
  if conclave-workspace --data-dir "$TEMP/state" --json health > "$TEMP/health.json" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then cat "$TEMP/service.log"; exit 1; fi
conclave-workspace --data-dir "$TEMP/state" --json version > "$TEMP/version.json"
conclave-workspace --data-dir "$TEMP/state" --json updates > "$TEMP/updates.json"
python3 - "$TEMP" "$CONCLAVE_WORKSPACE_VERSION" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
assert json.loads((root / 'health.json').read_text())['healthy'] is True
assert json.loads((root / 'version.json').read_text())['version'] == sys.argv[2]
assert json.loads((root / 'updates.json').read_text()) == {'phase': 'managed', 'packageManager': 'apt'}
engine = subprocess.run(['/usr/lib/conclave-workspace/assets/engines/conclave_cli_worker_engine'], capture_output=True, text=True, timeout=10)
assert engine.returncode == 64 and 'Engine options are incomplete or invalid' in engine.stderr
PY
kill "$service_pid"
wait "$service_pid"
service_pid=''
echo "Public APT signature, installation, service version/health, update ownership and Engine startup verified: $CONCLAVE_WORKSPACE_VERSION ($(dpkg --print-architecture))."
