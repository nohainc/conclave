#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-agent-macos.sh --app-bundle PATH --engine PATH [--version VERSION]

Installs the Flutter Agent App and registers the Dart Agent Engine as a
per-user launch-at-login service. Credentials and enrollment are configured
by the Agent App; this script never writes them to the launch agent.
EOF
}

app_bundle=""
engine=""
version="${CONCLAVE_AGENT_VERSION:-0.1.0}"
while (($# > 0)); do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app_bundle="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      engine="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_bundle" && -d "$app_bundle" ]] || {
  echo "Agent App bundle does not exist: $app_bundle" >&2
  exit 1
}
[[ -n "$engine" && -f "$engine" ]] || {
  echo "Agent Engine executable does not exist: $engine" >&2
  exit 1
}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || {
  echo "Invalid Agent version: $version" >&2
  exit 2
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

support_dir="${HOME}/Library/Application Support/Conclave AX"
app_destination="${HOME}/Applications/Conclave AX.app"
launch_agents="${HOME}/Library/LaunchAgents"
label="com.conclaveax.agent-engine"
plist="${launch_agents}/${label}.plist"
engine_destination="${support_dir}/bin/conclave_agent_engine"
log_dir="${support_dir}/logs"

escaped_engine_destination="$(xml_escape "$engine_destination")"
escaped_version="$(xml_escape "$version")"
escaped_log_dir="$(xml_escape "$log_dir")"

mkdir -p "${HOME}/Applications" "$support_dir/bin" "$log_dir" "$launch_agents"
rm -rf "$app_destination"
cp -R "$app_bundle" "$app_destination"
install -m 0755 "$engine" "$engine_destination"

if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${label}"
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escaped_engine_destination}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CONCLAVE_AGENT_VERSION</key>
    <string>${escaped_version}</string>
  </dict>
  <key>StandardOutPath</key>
    <string>${escaped_log_dir}/engine.out.log</string>
  <key>StandardErrorPath</key>
    <string>${escaped_log_dir}/engine.err.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Installed Conclave AX Agent ${version}; Engine service is active."
