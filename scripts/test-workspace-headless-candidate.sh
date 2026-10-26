#!/usr/bin/env bash
# Isolated Linux acceptance: no account, provider CLI, sudo or public listener.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'This acceptance check requires Linux.' >&2; exit 1; }
BUNDLE="${1:?Pass the built Linux service bundle directory}"
CHECK_ROOT="$(mktemp -d /tmp/cws-setup.XXXXXX)"
service_pid=''
cleanup() {
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fi
  rm -rf "$CHECK_ROOT"
}
trap cleanup EXIT
# Deliberately unreachable loopback Cloud: fake login data cannot leave this
# host or create remote registration. A user bus alone must not pick a keyring.
CONCLAVE_WORKSPACE_CLOUD_URL=http://127.0.0.1:9 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/conclave-no-secret-service \
  "$BUNDLE/conclave-service" --data-dir "$CHECK_ROOT/state" --work-root "$CHECK_ROOT/work" > "$CHECK_ROOT/service.log" 2>&1 &
service_pid=$!
ready=0
for _ in $(seq 1 40); do
  if "$BUNDLE/conclave-workspace" --data-dir "$CHECK_ROOT/state" health > "$CHECK_ROOT/health.json" 2>/dev/null; then ready=1; break; fi
  sleep 0.25
done
[[ "$ready" == 1 ]] || { cat "$CHECK_ROOT/service.log"; exit 1; }
if printf '%s\n' 'headless-test@example.invalid' 'nonsecret-test-password' |
  "$BUNDLE/conclave-workspace" --data-dir "$CHECK_ROOT/state" login --password > "$CHECK_ROOT/login.json"; then
  echo 'Unreachable Cloud must not complete login.' >&2; exit 1
fi
python3 - "$CHECK_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
assert json.loads((root / 'health.json').read_text())['healthy'] is True
status = json.loads((root / 'login.json').read_text())
assert status['phase'] == 'failed', status
assert status['stage'] == 'password_sign_in', status
assert (root / 'state/credential-store').read_text() == 'file'
assert not list((root / 'state/Credentials').glob('*.secret')), 'Probe must clean up'
assert not (root / 'state/workspace-registration.json').exists()
for path in root.rglob('*'):
    if path.is_file():
        assert b'nonsecret-test-password' not in path.read_bytes(), path
PY
kill "$service_pid"
wait "$service_pid"
service_pid=''
echo 'Headless storage preflight, offline diagnostics, password privacy and clean shutdown passed with zero Workers.'
