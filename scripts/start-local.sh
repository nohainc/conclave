#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Development & Testing Server (Production D1 Database)
# ==============================================================================
# Starts the Cloudflare Worker backend in a dedicated terminal window (for live
# logs) and launches the Flutter Web Studio in the default browser, connected
# directly to the remote production D1 database (`conclave-production`) & R2.
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
BUILD_MODE="release"
SKIP_BUILD=false
WATCH_MODE=false
OPEN_TERMINAL=true
OPEN_BROWSER=true
WATCHER_PID=""

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat << EOF
${BOLD}Conclave AX - Local Server (Production Database)${RESET}

${BOLD}USAGE:${RESET}
  ./scripts/start-local.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
  -p, --port <port>       Port to listen on (default: ${PORT})
  -i, --ip <ip>           IP address to bind (default: ${IP})
  -d, --debug             Build Flutter in debug mode (faster compilation)
  -s, --skip-build        Skip Flutter web build (uses existing build/web)
  -w, --watch             Watch Flutter source files and rebuild on changes
  --no-terminal           Run API server in current terminal instead of opening a new window
  --no-browser            Do not automatically open the browser when ready
  -h, --help              Show this help message

${BOLD}DESCRIPTION:${RESET}
  Runs the Cloudflare Worker API backend and the Flutter Web Studio application
  using Cloudflare Wrangler with ${BOLD}--remote${RESET} bindings.
  
  - ${BOLD}Backend:${RESET} Cloudflare Workers API (/api/*, /health, Realtime / Host WebSockets)
  - ${BOLD}Frontend:${RESET} Conclave AX Web Studio (served directly via Cloudflare Assets)
  - ${BOLD}Database:${RESET} Remote Production D1 Database (${CYAN}conclave-production${RESET})
  - ${BOLD}Storage:${RESET}  Remote Production R2 Bucket (${CYAN}conclave-artifacts-production${RESET})
  - ${BOLD}Logs:${RESET}     Dedicated terminal window for real-time API logs & worker console
  - ${BOLD}Browser:${RESET}  Opens http://${IP}:${PORT} automatically once the server is healthy

${BOLD}EXAMPLES:${RESET}
  ./scripts/start-local.sh                    # Build, launch terminal for logs & open browser
  ./scripts/start-local.sh --skip-build       # Fast restart without rebuilding web app
  ./scripts/start-local.sh --debug            # Debug mode for faster builds
  ./scripts/start-local.sh --no-terminal      # Run directly in foreground (CI / single window)
EOF
  exit 0
}

cleanup() {
  if [ -n "${WATCHER_PID}" ] && kill -0 "${WATCHER_PID}" 2>/dev/null; then
    echo -e "\n${YELLOW}[INFO] Stopping background watcher...${RESET}"
    kill "${WATCHER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -i|--ip)
      IP="$2"
      shift 2
      ;;
    -d|--debug)
      BUILD_MODE="debug"
      shift
      ;;
    -s|--skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -w|--watch)
      WATCH_MODE=true
      shift
      ;;
    --no-terminal)
      OPEN_TERMINAL=false
      shift
      ;;
    --no-browser)
      OPEN_BROWSER=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${RED}[ERROR] Unknown option: $1${RESET}"
      echo "Run './scripts/start-local.sh --help' for usage."
      exit 1
      ;;
  esac
done

TARGET_URL="http://${IP}:${PORT}"

echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${BOLD}${BLUE}  Conclave AX - Local Development Server${RESET}"
echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${CYAN}• Environment:${RESET}  Production (Remote D1 & R2)"
echo -e "${CYAN}• Target DB:${RESET}    conclave-production (e3729ad9-009a-4626-b401-cd218cdb5885)"
echo -e "${CYAN}• Local URL:${RESET}    ${TARGET_URL}"
echo -e "${CYAN}• Config:${RESET}       infra/cloudflare/app.wrangler.jsonc"
echo -e "${CYAN}• Terminal:${RESET}     $([ "${OPEN_TERMINAL}" = true ] && echo "Dedicated window for API logs" || echo "Current terminal")"
echo -e "${CYAN}• Browser:${RESET}      $([ "${OPEN_BROWSER}" = true ] && echo "Auto-open on server ready" || echo "Manual")"
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

# Build Flutter Web App
build_flutter_web() {
  local mode="$1"
  echo -e "${GREEN}[BUILD] Compiling Flutter Web Studio (${mode} mode)...${RESET}"
  
  local build_flags=(
    build web
    "--${mode}"
    "--dart-define=CONCLAVE_API_URL=/api"
  )
  
  if [ "${mode}" = "release" ]; then
    build_flags+=("--no-wasm-dry-run")
  fi

  (
    cd "${ROOT_DIR}/apps/app"
    flutter "${build_flags[@]}"
  )
  echo -e "${GREEN}[BUILD] Web assets ready in apps/app/build/web${RESET}\n"
}

if [ "${SKIP_BUILD}" = true ]; then
  if [ ! -d "${ROOT_DIR}/apps/app/build/web" ]; then
    echo -e "${YELLOW}[WARN] apps/app/build/web not found. Building despite --skip-build flag...${RESET}"
    build_flutter_web "${BUILD_MODE}"
  else
    echo -e "${BLUE}[INFO] Skipping Flutter build (using existing build/web)${RESET}\n"
  fi
else
  build_flutter_web "${BUILD_MODE}"
fi

# Function to launch browser
open_browser() {
  local url="$1"
  echo -e "${GREEN}[BROWSER] Opening ${url} in default browser...${RESET}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    open "${url}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${url}" >/dev/null 2>&1 || true
  elif command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c start "${url}" >/dev/null 2>&1 || true
  else
    echo -e "${YELLOW}[WARN] Could not automatically open browser. Visit: ${url}${RESET}"
  fi
}

# Function to wait for server health
wait_for_server() {
  local url="$1"
  local max_attempts=60
  local attempt=1
  echo -e "${CYAN}[WAIT] Waiting for server to become ready at ${url}/health...${RESET}"
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s -f "${url}/health" >/dev/null 2>&1; then
      echo -e "${GREEN}[SUCCESS] Server is healthy and ready!${RESET}\n"
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
echo -e "\033[0;36m• URL:\033[0m       ${TARGET_URL}"
echo -e "\033[1m\033[0;34m=================================================================\033[0m\n"

exec ${WRANGLER_BIN} dev \\
  --remote \\
  --config "${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${TARGET_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${TARGET_URL},http://localhost:${PORT},https://app.conclaveax.com"
EOF
chmod +x "${RUNNER_SCRIPT}"

# Launch API backend in dedicated terminal or in-place
if [ "${OPEN_TERMINAL}" = true ]; then
  if [[ "$OSTYPE" == "darwin"* ]] && command -v osascript >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in a new Terminal window...${RESET}"
    osascript -e "tell application \"Terminal\" to do script \"${RUNNER_SCRIPT}\"" >/dev/null 2>&1
    osascript -e "tell application \"Terminal\" to activate" >/dev/null 2>&1
  elif command -v x-terminal-emulator >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in x-terminal-emulator...${RESET}"
    x-terminal-emulator -e "${RUNNER_SCRIPT}" &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in gnome-terminal...${RESET}"
    gnome-terminal -- "${RUNNER_SCRIPT}" &
  elif command -v konsole >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in konsole...${RESET}"
    konsole -e "${RUNNER_SCRIPT}" &
  elif command -v kitty >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in kitty...${RESET}"
    kitty "${RUNNER_SCRIPT}" &
  elif command -v alacritty >/dev/null 2>&1; then
    echo -e "${GREEN}[TERMINAL] Launching API backend in alacritty...${RESET}"
    alacritty -e "${RUNNER_SCRIPT}" &
  else
    echo -e "${YELLOW}[WARN] No GUI terminal emulator detected. Running in background...${RESET}"
    "${RUNNER_SCRIPT}" &
  fi

  # Wait for server to be responsive
  wait_for_server "${TARGET_URL}" || true

  # Open browser if enabled
  if [ "${OPEN_BROWSER}" = true ]; then
    open_browser "${TARGET_URL}"
  fi

  echo -e "${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${BOLD}${GREEN}  Conclave AX Local Stack is LIVE!${RESET}"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}"
  echo -e "${CYAN}• Web Studio URL:${RESET}  ${BOLD}${TARGET_URL}${RESET}"
  echo -e "${CYAN}• Health Check:${RESET}    ${TARGET_URL}/health"
  echo -e "${CYAN}• API Logs:${RESET}        Streaming in the dedicated Terminal window"
  echo -e "${CYAN}• Database:${RESET}        Remote Production D1 (${CYAN}conclave-production${RESET})"
  echo -e "${BOLD}${GREEN}=================================================================${RESET}\n"
else
  # Foreground execution (no new terminal window)
  if [ "${OPEN_BROWSER}" = true ]; then
    (
      wait_for_server "${TARGET_URL}" && open_browser "${TARGET_URL}"
    ) &
  fi
  exec "${RUNNER_SCRIPT}"
fi
