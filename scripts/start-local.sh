#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Development & Testing Server (Production D1 Database)
# ==============================================================================
# 1. Starts the Cloudflare Worker API backend in a dedicated terminal window
#    (for live request logs) connected to remote production D1 & R2.
# 2. Starts the Flutter Web Studio app in the active console with Hot Reload
#    ('r' to reload, 'R' to restart) and opens Chrome automatically.
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
MODE="interactive" # 'interactive' (flutter run) or 'assets' (wrangler assets)
OPEN_TERMINAL=true
API_PID=""

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat << EOF
${BOLD}Conclave AX - Local Server (Production Database)${RESET}

${BOLD}USAGE:${RESET}
  ./start-local.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
  -d, --device <device>   Flutter device to run: chrome or web-server (default: ${DEVICE})
  -p, --port <port>       Backend API port (default: ${PORT})
  -i, --ip <ip>           Backend IP address (default: ${IP})
  --web-port <port>       Port for Flutter web-server mode
  -a, --assets            Serve pre-compiled static assets via Wrangler instead of flutter run
  --no-terminal           Run API server in background instead of opening a new terminal window
  -h, --help              Show this help message

${BOLD}INTERACTIVE CONTROLS:${RESET}
  In the active Flutter console:
  - Press ${BOLD}r${RESET} to Hot Reload changes instantly
  - Press ${BOLD}R${RESET} to Hot Restart the web application
  - Press ${BOLD}h${RESET} to view all Flutter commands
  - Press ${BOLD}q${RESET} to quit and stop both the app and the backend

${BOLD}ARCHITECTURE:${RESET}
  - ${BOLD}Frontend Console:${RESET} Active Flutter Dev server with Hot Reload (r/R) + Chrome browser
  - ${BOLD}Backend Console:${RESET}  Dedicated terminal window with live Cloudflare Worker API logs
  - ${BOLD}Database:${RESET}         Remote Production D1 Database (${CYAN}conclave-production${RESET})
  - ${BOLD}Storage:${RESET}          Remote Production R2 Bucket (${CYAN}conclave-artifacts-production${RESET})

${BOLD}EXAMPLES:${RESET}
  ./start-local.sh                          # Start interactive dev mode with hot-reload (r/R)
  ./start-local.sh --device web-server      # Use generic web-server instead of Chrome
  ./start-local.sh --assets                 # Serve compiled static build via Cloudflare Assets
EOF
  exit 0
}

cleanup() {
  if [ -n "${API_PID}" ] && kill -0 "${API_PID}" 2>/dev/null; then
    echo -e "\n${YELLOW}[INFO] Stopping background API server...${RESET}"
    kill "${API_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

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
    -a|--assets)
      MODE="assets"
      shift
      ;;
    --no-terminal)
      OPEN_TERMINAL=false
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

echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${BOLD}${BLUE}  Conclave AX - Local Development Stack${RESET}"
echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${CYAN}• Mode:${RESET}          $([ "${MODE}" = "interactive" ] && echo "Interactive Flutter (Hot Reload: 'r' / Restart: 'R')" || echo "Static Production Assets")"
echo -e "${CYAN}• Backend API:${RESET}   ${API_URL}"
echo -e "${CYAN}• Target DB:${RESET}     conclave-production (e3729ad9-009a-4626-b401-cd218cdb5885)"
echo -e "${CYAN}• API Logs:${RESET}      $([ "${OPEN_TERMINAL}" = true ] && echo "Dedicated Terminal Window" || echo "Background Process")"
echo -e "${BOLD}${BLUE}=================================================================${RESET}\n"

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

# Function to wait for backend server readiness
wait_for_server() {
  local url="$1"
  local max_attempts=60
  local attempt=1
  echo -e "${CYAN}[WAIT] Waiting for API backend to connect to production resources...${RESET}"
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s -f "${url}/health" >/dev/null 2>&1; then
      echo -e "${GREEN}[SUCCESS] API Backend is healthy and ready!${RESET}\n"
      return 0
    fi
    sleep 0.5
    attempt=$((attempt + 1))
  done

  echo -e "${YELLOW}[WARN] Timed out waiting for ${url}/health, but proceeding...${RESET}\n"
  return 1
}

# Create executable runner script for the dedicated terminal
RUNNER_SCRIPT="/tmp/conclave-api-dev-${PORT}.sh"
cat << EOF > "${RUNNER_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;34m=================================================================\033[0m"
echo -e "\033[1m\033[0;34m  Conclave AX - API Backend Logs (Wrangler + Remote Production)\033[0m"
echo -e "\033[1m\033[0;34m=================================================================\033[0m"
echo -e "\033[0;36m• Target DB:\033[0m conclave-production"
echo -e "\033[0;36m• API Base:\033[0m  ${API_URL}"
echo -e "\033[1m\033[0;34m=================================================================\033[0m\n"

exec ${WRANGLER_BIN} dev \\
  --remote \\
  --config "${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${API_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${API_URL},http://localhost:${PORT},http://localhost:3000,http://127.0.0.1:3000,https://app.conclaveax.com"
EOF
chmod +x "${RUNNER_SCRIPT}"

# Step 1: Launch Backend API in Dedicated Terminal or Background
if [ "${OPEN_TERMINAL}" = true ]; then
  if [[ "$OSTYPE" == "darwin"* ]] && command -v osascript >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Opening API backend logs in a new Terminal window...${RESET}"
    osascript -e "tell application \"Terminal\" to do script \"${RUNNER_SCRIPT}\"" >/dev/null 2>&1
    osascript -e "tell application \"Terminal\" to activate" >/dev/null 2>&1
  elif command -v x-terminal-emulator >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Opening API backend logs in x-terminal-emulator...${RESET}"
    x-terminal-emulator -e "${RUNNER_SCRIPT}" &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Opening API backend logs in gnome-terminal...${RESET}"
    gnome-terminal -- "${RUNNER_SCRIPT}" &
  else
    echo -e "${YELLOW}[WARN] No GUI terminal detected. Running API backend in background...${RESET}"
    "${RUNNER_SCRIPT}" &
    API_PID=$!
  fi
else
  echo -e "${GREEN}[SERVER] Starting API backend in background...${RESET}"
  "${RUNNER_SCRIPT}" &
  API_PID=$!
fi

# Step 2: Wait for Backend API Health
wait_for_server "${API_URL}" || true

# Step 3: Launch Web Frontend
if [ "${MODE}" = "interactive" ]; then
  echo -e "${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${BOLD}${GREEN}  Launching Interactive Flutter Web Console${RESET}"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${CYAN}• Interactive keys:${RESET}"
  echo -e "  - Press ${BOLD}r${RESET} to Hot Reload"
  echo -e "  - Press ${BOLD}R${RESET} to Hot Restart"
  echo -e "  - Press ${BOLD}q${RESET} to Quit"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}\n"

  FLUTTER_ARGS=(
    run
    "-d" "${DEVICE}"
    "--dart-define=CONCLAVE_API_URL=${API_URL}/api"
  )

  if [ -n "${WEB_PORT}" ]; then
    FLUTTER_ARGS+=("--web-port=${WEB_PORT}")
  fi

  cd "${ROOT_DIR}/apps/app"
  exec flutter "${FLUTTER_ARGS[@]}"

else
  # Static Assets Mode: Open browser at the Wrangler unified port
  echo -e "${GREEN}[BROWSER] Opening ${API_URL} in default browser...${RESET}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    open "${API_URL}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${API_URL}" >/dev/null 2>&1 || true
  fi

  echo -e "${BOLD}${GREEN}Stack is running! Press Ctrl+C to stop.${RESET}"
  wait
fi
