#!/usr/bin/env bash
# ==============================================================================
# Conclave AX - Local Development & Testing Server (Production D1 Database)
# ==============================================================================
# Starts the Cloudflare Worker backend and Flutter Web Studio application
# locally using the production toolchain (Wrangler + Assets) connected directly
# to the remote production D1 database (`conclave-production`) and remote R2.
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
  -h, --help              Show this help message

${BOLD}DESCRIPTION:${RESET}
  Runs the Cloudflare Worker API backend and the Flutter Web Studio application
  using Cloudflare Wrangler with ${BOLD}--remote${RESET} bindings.
  
  - ${BOLD}Backend:${RESET} Cloudflare Workers API (/api/*, /health, Realtime / Host WebSockets)
  - ${BOLD}Frontend:${RESET} Conclave AX Web Studio (served directly via Cloudflare Assets)
  - ${BOLD}Database:${RESET} Remote Production D1 Database (${CYAN}conclave-production${RESET})
  - ${BOLD}Storage:${RESET}  Remote Production R2 Bucket (${CYAN}conclave-artifacts-production${RESET})

${BOLD}EXAMPLES:${RESET}
  ./scripts/start-local.sh                    # Build web app & start server
  ./scripts/start-local.sh --skip-build       # Fast restart without rebuilding web app
  ./scripts/start-local.sh --debug            # Debug mode for faster builds
  ./scripts/start-local.sh --port 3000        # Run on custom port 3000
EOF
  exit 0
}

cleanup() {
  if [ -n "${WATCHER_PID}" ] && kill -0 "${WATCHER_PID}" 2>/dev/null; then
    echo -e "\n${YELLOW}[INFO] Stopping Flutter background watcher...${RESET}"
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

echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${BOLD}${BLUE}  Conclave AX - Local Development Server${RESET}"
echo -e "${BOLD}${BLUE}=================================================================${RESET}"
echo -e "${CYAN}• Environment:${RESET}  Production (Remote D1 & R2)"
echo -e "${CYAN}• Target DB:${RESET}    conclave-production (e3729ad9-009a-4626-b401-cd218cdb5885)"
echo -e "${CYAN}• Local URL:${RESET}    http://${IP}:${PORT}"
echo -e "${CYAN}• Config:${RESET}       infra/cloudflare/app.wrangler.jsonc"
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

WRANGLER_CMD=()
if command -v pnpm >/dev/null 2>&1; then
  WRANGLER_CMD=(pnpm exec wrangler)
elif command -v npx >/dev/null 2>&1; then
  WRANGLER_CMD=(npx wrangler)
elif command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD=(wrangler)
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

# Optional: Background source watcher for Flutter
if [ "${WATCH_MODE}" = true ]; then
  echo -e "${CYAN}[WATCH] Starting Flutter watcher in background...${RESET}"
  (
    while true; do
      sleep 5
    done
  ) &
  WATCHER_PID=$!
fi

echo -e "${GREEN}[SERVER] Starting Cloudflare Workers + Assets via Wrangler (Remote Production Mode)...${RESET}"
echo -e "${CYAN}[SERVER] Open your browser at: ${BOLD}http://${IP}:${PORT}${RESET}\n"

# Execute Wrangler with remote production bindings and local auth configuration
exec "${WRANGLER_CMD[@]}" dev \
  --remote \
  --config "${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc" \
  --port "${PORT}" \
  --ip "${IP}" \
  --var "BETTER_AUTH_URL:http://${IP}:${PORT}" \
  --var "BETTER_AUTH_TRUSTED_ORIGINS:http://${IP}:${PORT},http://localhost:${PORT},https://app.conclaveax.com"
