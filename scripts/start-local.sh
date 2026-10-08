#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Stack Launcher
# ==============================================================================
# Launches 2 dedicated terminal windows in parallel:
#   1. Backend API: Cloudflare Wrangler with the local v8 D1 database
#   2. AX web app: Flutter run with Hot Reload ('r'/'R') + Google Chrome
#
# Prints 2 concise status lines on the main terminal and exits immediately.
# ==============================================================================

set -euo pipefail

# ANSI color codes
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

PORT="${PORT:-8787}"
# Keep the server bind address separate from the browser-facing hostname.
# `localhost` and `127.0.0.1` are different cookie sites, so using one for
# the API and the other for Flutter causes Better Auth's session cookie to be
# omitted from the follow-up /api/session request.
IP="${IP:-127.0.0.1}"
API_HOST="${API_HOST:-localhost}"
DEVICE="${DEVICE:-chrome}"
WEB_PORT="${WEB_PORT:-3000}"
ISOLATED=false
WEB_BUILD_MODE=debug

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: pnpm start:local [--isolated] [--web-release] [-p port] [-d device] [-i ip] [--web-port port] [--api-host host]"
}

option_value() {
  local option="$1"
  if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
    echo "Error: ${option} requires a value." >&2
    usage >&2
    exit 2
  fi
}

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-release)
      WEB_BUILD_MODE=release
      shift
      ;;
    --isolated)
      ISOLATED=true
      shift
      ;;
    -d|--device)
      option_value "$@"
      DEVICE="$2"
      shift 2
      ;;
    -p|--port)
      option_value "$@"
      PORT="$2"
      shift 2
      ;;
    -i|--ip)
      option_value "$@"
      IP="$2"
      shift 2
      ;;
    --api-host)
      option_value "$@"
      API_HOST="$2"
      shift 2
      ;;
    --web-port)
      option_value "$@"
      WEB_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

API_URL="http://${API_HOST}:${PORT}"
WEB_URL="http://localhost:${WEB_PORT}"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "${FLUTTER_BIN}" && -x "/Users/${USER}/development/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="/Users/${USER}/development/flutter/bin/flutter"
fi
if [[ -z "${FLUTTER_BIN}" || ! -x "${FLUTTER_BIN}" ]]; then
  echo "Error: Flutter SDK was not found. Set FLUTTER_BIN to its flutter executable." >&2
  exit 1
fi
FLUTTER_ROOT="$(cd "$(dirname "${FLUTTER_BIN}")/.." && pwd)"
FLUTTER_ENGINE_VERSION="$(<"${FLUTTER_ROOT}/bin/internal/engine.version")"
if [[ "$ISOLATED" == true ]]; then
  node "$ROOT_DIR/scripts/setup-development-auth.mjs"
  node "$ROOT_DIR/scripts/setup-development-profile-signing.mjs"
  API_CONFIG="$ROOT_DIR/apps/cloud/wrangler.jsonc"
  API_MODE="isolated local v8 D1"
else
  API_CONFIG="$ROOT_DIR/scripts/local-cloud-proxy.wrangler.jsonc"
  API_MODE="production Cloud gateway — live accounts and data"
fi

# 1. Runner Script for Backend API
RUNNER_API="/tmp/conclave-api-dev-${PORT}.sh"
cat << EOF > "${RUNNER_API}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;34m[Conclave AX API Backend Logs]\033[0m ${API_MODE} | Base: ${API_URL}\n"
exec pnpm exec wrangler dev \\
  --config "${API_CONFIG}" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${API_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${API_URL},${WEB_URL},http://localhost:${PORT},http://127.0.0.1:${PORT},https://app.conclaveax.com"
EOF
chmod +x "${RUNNER_API}"

# 2. Runner Script for Frontend Web App
if [[ "$WEB_BUILD_MODE" == release ]]; then
  WEB_CONTROLS="Release rendering | [q] Quit | stop and relaunch to rebuild"
else
  WEB_CONTROLS="Controls: [r] Reload | [R] Restart | [q] Quit"
fi
RUNNER_FLUTTER="/tmp/conclave-flutter-dev-${PORT}.sh"
cat << EOF > "${RUNNER_FLUTTER}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}/apps/app"
echo -e "\033[1m\033[0;32m[Conclave AX Flutter Web]\033[0m ${WEB_CONTROLS}\n"
export FLUTTER_PREBUILT_ENGINE_VERSION="${FLUTTER_ENGINE_VERSION}"
exec "${FLUTTER_BIN}" run --${WEB_BUILD_MODE} -d "${DEVICE}" --web-port="${WEB_PORT}" --dart-define="CONCLAVE_API_URL=${API_URL}/api"
EOF
chmod +x "${RUNNER_FLUTTER}"

# Function to spawn a terminal
spawn_terminal() {
  local script_path="$1"
  local title="$2"
  if [[ "$OSTYPE" == "darwin"* ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application \"Terminal\" to do script \"${script_path}\"" >/dev/null 2>&1
    osascript -e "tell application \"Terminal\" to activate" >/dev/null 2>&1
  elif command -v x-terminal-emulator >/dev/null 2>&1; then
    x-terminal-emulator -T "${title}" -e "${script_path}" &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal --title="${title}" -- "${script_path}" &
  elif command -v konsole >/dev/null 2>&1; then
    konsole --title "${title}" -e "${script_path}" &
  elif command -v kitty >/dev/null 2>&1; then
    kitty --title "${title}" "${script_path}" &
  elif command -v alacritty >/dev/null 2>&1; then
    alacritty --title "${title}" -e "${script_path}" &
  else
    "${script_path}" &
  fi
}

# Launch both terminals in parallel
spawn_terminal "${RUNNER_API}" "Conclave AX - API Backend"
spawn_terminal "${RUNNER_FLUTTER}" "Conclave AX - Web App"

# Print exactly 2 concise lines and exit immediately
echo -e "${GREEN}✓ Conclave AX started in 2 new terminals (Backend & Frontend in parallel).${RESET}"
echo -e "${CYAN}• Web App:${RESET} ${BOLD}${WEB_URL}${RESET} | ${CYAN}API:${RESET} ${BOLD}${API_URL}${RESET} (${API_MODE})"
