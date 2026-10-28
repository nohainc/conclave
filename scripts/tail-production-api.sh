#!/usr/bin/env bash
# ==============================================================================
# Syntila - Tail Production Cloudflare Worker Logs
# ==============================================================================
# Opens a dedicated terminal streaming live production Worker logs via Wrangler.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRANGLER_CONFIG="${ROOT_DIR}/infra/cloudflare/app.wrangler.jsonc"

RUNNER_TAIL="/tmp/syntila-tail-production-api.sh"
cat << EOF > "${RUNNER_TAIL}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;35m[Syntila Production API Live Logs]\033[0m Streaming from Cloudflare...\n"
exec pnpm exec wrangler tail --config "${WRANGLER_CONFIG}"
EOF
chmod +x "${RUNNER_TAIL}"

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

spawn_terminal "${RUNNER_TAIL}" "Syntila - Production API Logs"
echo "✓ Spawned live log tail in a new terminal window for production API (conclave-ax-app)."
