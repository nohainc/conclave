#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Development & Testing Launcher (Production D1 Database)
# ==============================================================================
# Launches 2 dedicated terminal windows:
#   1. Backend API Logs: Cloudflare Wrangler connected to remote production D1
#   2. Frontend Web Console: Flutter run with Hot Reload ('r'/'R') + Google Chrome
#
# The invoking terminal displays stack status and exits cleanly.
# ==============================================================================

set -euo pipefail

# ANSI color codes
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

# Default configuration
PORT="8787"
IP="127.0.0.1"
DEVICE="chrome"
WEB_PORT=""
SPAWN_TERMINALS=true

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat << EOF
${BOLD}Conclave AX - Local Stack Launcher (Production Database)${RESET}

${BOLD}USAGE:${RESET}
  ./start-local.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
  -d, --device <device>   Flutter web device: chrome or web-server (default: ${DEVICE})
  -p, --port <port>       Backend API port (default: ${PORT})
  -i, --ip <ip>           Backend IP address (default: ${IP})
  --web-port <port>       Port for Flutter web-server mode
  --foreground            Run in foreground instead of spawning 2 new terminal windows
  -h, --help              Show this help message

${BOLD}BEHAVIOR:${RESET}
  Spawns ${BOLD}2 new terminal windows${RESET} while keeping this terminal clean:
  1. ${BOLD}Terminal 1 (Backend API):${RESET} Cloudflare Wrangler streaming live logs
  2. ${BOLD}Terminal 2 (Frontend Web):${RESET} Flutter Interactive Console with Hot Reload ('r'/'R')
  3. ${BOLD}Browser:${RESET} Google Chrome automatically launched with Conclave Web Studio

${BOLD}INTERACTIVE CONTROLS:${RESET}
  Inside the Frontend Web terminal:
  - Press ${BOLD}r${RESET} to Hot Reload changes
  - Press ${BOLD}R${RESET} to Hot Restart the app
  - Press ${BOLD}h${RESET} for Flutter help
  - Press ${BOLD}q${RESET} to quit

${BOLD}EXAMPLES:${RESET}
  ./start-local.sh                    # Launch backend & frontend in 2 new terminals
  ./start-local.sh --device web-server # Launch using web-server target
  ./start-local.sh --port 3000        # Custom backend port
EOF
  exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)
      DEVICE="$2"
      shift 2
      ;;
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -i|--ip)
      IP="$2"
      shift 2
      ;;
    --web-port)
      WEB_PORT="$2"
      shift 2
      ;;
    --foreground)
      SPAWN_TERMINALS=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${RED}[ERROR] Unknown option: $1${RESET}"
      echo "Run './start-local.sh --help' for usage."
      exit 1
      ;;
  esac
done

API_URL="http://${IP}:${PORT}"

# Verify required tools
if ! command -v flutter >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] 'flutter' CLI is required but was not found in PATH.${RESET}"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] 'node' is required but was not found in PATH.${RESET}"
  exit 1
fi

WRANGLER_BIN=""
if command -v pnpm >/dev/null 2>&1; then
  WRANGLER_BIN="pnpm exec wrangler"
elif command -v npx >/dev/null 2>&1; then
  WRANGLER_BIN="npx wrangler"
elif command -v wrangler >/dev/null 2>&1; then
  WRANGLER_BIN="wrangler"
else
  echo -e "${RED}[ERROR] Could not locate pnpm, npx, or wrangler.${RESET}"
  exit 1
fi

# Function to spawn a command in a new terminal window
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
    echo -e "${YELLOW}[WARN] No terminal emulator found. Running in background...${RESET}"
    "${script_path}" &
  fi
}

# Function to wait for backend server readiness
wait_for_server() {
  local url="$1"
  local max_attempts=60
  local attempt=1
  echo -e "${CYAN}[WAIT] Waiting for API Backend to initialize production bindings...${RESET}"
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s -f "${url}/health" >/dev/null 2>&1; then
      echo -e "${GREEN}[SUCCESS] API Backend is healthy and ready!${RESET}\n"
      return 0
    fi
    sleep 0.5
    attempt=$((attempt + 1))
  done

  echo -e "${YELLOW}[WARN] Backend startup took longer than expected, proceeding with frontend launch...${RESET}\n"
  return 1
}

# 1. Create Runner Script for Terminal 1 (Backend API)
RUNNER_API="/tmp/conclave-api-dev-${PORT}.sh"
cat << EOF > "${RUNNER_API}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;34m=================================================================\033[0m"
echo -e "\033[1m\033[0;34m  Conclave AX - API Backend Logs (Wrangler + Remote Production)\033[0m"
echo -e "\033[1m\033[0;34m=================================================================\033[0m"
echo -e "\033[0;36m• Target DB:\033[0m conclave-production (Remote D1)"
echo -e "\033[0;36m• API URL:\033[0m   ${API_URL}"
echo -e "\033[0;36m• Endpoints:\033[0m /api/*, /health, Realtime / Host Gateways"
echo -e "\033[1m\033[0;34m=================================================================\033[0m\n"

exec ${WRANGLER_BIN} dev \\
  --remote \\
  --config "${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${API_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${API_URL},http://localhost:${PORT},http://localhost:3000,http://127.0.0.1:3000,https://app.conclaveax.com"
EOF
chmod +x "${RUNNER_API}"

# 2. Create Runner Script for Terminal 2 (Flutter Web Studio)
RUNNER_FLUTTER="/tmp/conclave-flutter-dev-${PORT}.sh"
FLUTTER_RUN_CMD="flutter run -d ${DEVICE} --dart-define=CONCLAVE_API_URL=${API_URL}/api"
if [ -n "${WEB_PORT}" ]; then
  FLUTTER_RUN_CMD+=" --web-port=${WEB_PORT}"
fi

cat << EOF > "${RUNNER_FLUTTER}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}/apps/app"
echo -e "\033[1m\033[0;32m=================================================================\033[0m"
echo -e "\033[1m\033[0;32m  Conclave AX - Interactive Flutter Web Studio\033[0m"
echo -e "\033[1m\033[0;32m=================================================================\033[0m"
echo -e "\033[0;36m• Device:\033[0m    ${DEVICE}"
echo -e "\033[0;36m• API Base:\033[0m  ${API_URL}/api"
echo -e "\033[0;36m• Controls:\033[0m"
echo -e "  - Press \033[1mr\033[0m to Hot Reload changes instantly"
echo -e "  - Press \033[1mR\033[0m to Hot Restart the application"
echo -e "  - Press \033[1mh\033[0m for Flutter CLI help"
echo -e "  - Press \033[1mq\033[0m to quit and close session"
echo -e "\033[1m\033[0;32m=================================================================\033[0m\n"

exec ${FLUTTER_RUN_CMD}
EOF
chmod +x "${RUNNER_FLUTTER}"

if [ "${SPAWN_TERMINALS}" = true ]; then
  echo -e "${BOLD}${BLUE}=================================================================${RESET}"
  echo -e "${BOLD}${BLUE}  Starting Conclave AX Local Stack...${RESET}"
  echo -e "${BOLD}${BLUE}=================================================================${RESET}\n"

  # Spawn Terminal 1: Backend API
  echo -e "${GREEN}[1/2] Spawning Backend API Terminal (Wrangler + Production D1)...${RESET}"
  spawn_terminal "${RUNNER_API}" "Conclave AX - API Backend Logs"

  # Wait for backend health
  wait_for_server "${API_URL}" || true

  # Spawn Terminal 2: Flutter Web Console
  echo -e "${GREEN}[2/2] Spawning Frontend Web Terminal (Flutter Hot Reload Console)...${RESET}"
  spawn_terminal "${RUNNER_FLUTTER}" "Conclave AX - Flutter Web Console"

  echo -e "\n${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${BOLD}${GREEN}  ✓ Conclave AX Local Stack Launched in 2 New Terminals!${RESET}"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${CYAN}• Terminal 1 (API):${RESET}      Streaming Cloudflare Worker logs (${API_URL})"
  echo -e "${CYAN}• Terminal 2 (Flutter):${RESET}  Active Console with Hot Reload ('r' / 'R')"
  echo -e "${CYAN}• Target Database:${RESET}       Remote Production D1 (${CYAN}conclave-production${RESET})"
  echo -e "${CYAN}• Browser:${RESET}               Google Chrome launching automatically"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}\n"
  echo -e "${BLUE}This terminal is now free for other commands.${RESET}\n"
else
  # Foreground mode: start API in background and run Flutter in current terminal
  "${RUNNER_API}" &
  API_PID=$!
  trap "kill ${API_PID} 2>/dev/null || true" EXIT INT TERM
  wait_for_server "${API_URL}" || true
  exec "${RUNNER_FLUTTER}"
fi
