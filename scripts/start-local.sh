#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Stack Launcher (Production D1 Database)
# ==============================================================================
# Launches 2 dedicated terminal windows in parallel:
#   1. Backend API: Cloudflare Wrangler connected to remote production D1
#   2. Frontend Web Studio: Flutter run with Hot Reload ('r'/'R') + Google Chrome
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
IP="${IP:-127.0.0.1}"
DEVICE="${DEVICE:-chrome}"
WEB_PORT="${WEB_PORT:-3000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device) DEVICE="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -i|--ip) IP="$2"; shift 2 ;;
    --web-port) WEB_PORT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./start-local.sh [-p port] [-d device] [--web-port port]"
      exit 0
      ;;
    *) shift ;;
  esac
done

API_URL="http://${IP}:${PORT}"
WEB_URL="http://localhost:${WEB_PORT}"

WRANGLER_BIN="pnpm exec wrangler"
if ! command -v pnpm >/dev/null 2>&1; then
  if command -v npx >/dev/null 2>&1; then
    WRANGLER_BIN="npx wrangler"
  else
    WRANGLER_BIN="wrangler"
  fi
fi

# 1. Runner Script for Backend API
RUNNER_API="/tmp/conclave-api-dev-${PORT}.sh"
cat << EOF > "${RUNNER_API}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;34m[Conclave AX API Backend Logs]\033[0m Target DB: conclave-production (Remote D1) | Base: ${API_URL}\n"
exec ${WRANGLER_BIN} dev \\
  --remote \\
  --config "${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${API_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${API_URL},${WEB_URL},http://localhost:${PORT},http://127.0.0.1:${PORT},https://app.conclaveax.com"
EOF
chmod +x "${RUNNER_API}"

# 2. Runner Script for Frontend Web App
RUNNER_FLUTTER="/tmp/conclave-flutter-dev-${PORT}.sh"
cat << EOF > "${RUNNER_FLUTTER}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}/apps/app"
echo -e "\033[1m\033[0;32m[Conclave AX Flutter Web Studio]\033[0m Controls: [r] Reload | [R] Restart | [q] Quit\n"
exec flutter run -d "${DEVICE}" --web-port="${WEB_PORT}" --dart-define="CONCLAVE_API_URL=${API_URL}/api"
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
spawn_terminal "${RUNNER_FLUTTER}" "Conclave AX - Web Studio"

# Print exactly 2 concise lines and exit immediately
echo -e "${GREEN}✓ Conclave AX started in 2 new terminals (Backend & Frontend in parallel).${RESET}"
echo -e "${CYAN}• Web Studio:${RESET} ${BOLD}${WEB_URL}${RESET} | ${CYAN}API:${RESET} ${BOLD}${API_URL}${RESET} (Production D1)"
