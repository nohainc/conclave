# Workspace on Linux

Linux x64/arm64 source support includes the Flutter management UI, the
standalone Dart Workspace Service, and the separately supervised generic CLI
Worker Engine (ADR-021). The bundle is an unsigned candidate with manual
updates; distro packages (deb/rpm/Flatpak) and release signing are later phases.

## Build

Flutter desktop cannot cross-compile; build on a Linux host of the target
architecture. Install Flutter, Node.js, and the GTK toolchain
(`clang cmake ninja-build pkg-config libgtk-3-dev`), run `flutter doctor -v`,
supply `CONCLAVE_RELEASE_TRUST_KEYS_JSON` with your public application-release
trust roots, then from the repository root:

```bash
bash scripts/build-workspace-linux.sh
```

This produces `dist/conclave-workspace/conclave-workspace-linux-<arch>-release.tar.gz`
from the canonical Engine and service builds. The **Build Linux Workspace**
Actions workflow builds x64 on Ubuntu, runs the Linux adapter tests, a packaged
service one-shot lifecycle, and a UI startup smoke test under Xvfb.

## Install and run (desktop)

Extract the whole archive to a stable per-user directory, e.g.
`~/.local/opt/conclave-workspace`, and run `./conclave_workspace`. The target
needs GTK 3. Register and start the service from the management UI.

- The service is a **systemd user unit**
  `~/.config/systemd/user/conclave-workspace-<installation-id>.service`, run as
  the logged-in user so provider CLIs see their own logins. Stop keeps the unit
  enabled; Disconnect Cloud keeps the service running; Unregister disables and
  removes only the unit file.
- To keep the service running without a login session (mini PC, server):
  `loginctl enable-linger "$USER"`.
- Moving the install directory changes the unit's `ExecStart`; the manager
  refuses to overwrite a unit that points to another executable. Unregister the
  old location first. State is preserved.
- Manual update: stop the service, replace the whole directory, start again.

## Headless hosts and containers

Run the service as the foreground main process; the supervisor/container owns
restarts and SIGTERM performs a graceful stop:

```bash
./conclave-service --data-dir /data/state --work-root /data/work
```

Persist the state root, Work Root, and the provider CLI credential directories
(`~/.claude`, `~/.codex`, `~/.gemini`) on volumes. A dedicated
`conclave-workspace` management CLI (ADR-021 §2.6) is not implemented yet.

## Platform behavior

- **State root:** `$XDG_STATE_HOME/conclave/workspace` (default
  `~/.local/state/conclave/workspace`). If a legacy `~/.conclave-workspace` root
  exists it remains authoritative in place; nothing is moved or re-registered.
  `CONCLAVE_WORKSPACE_DATA_DIR` / `--data-dir` override as on other platforms.
- **IPC:** Unix-domain socket `runtime/manager.sock` under the `0700` state
  root (not `$XDG_RUNTIME_DIR`), using the unchanged authenticated protocol.
- **Runtime credential:** Secret Service (`secret-tool`, libsecret) when a
  session D-Bus is present, otherwise a `0600` file under
  `<state>/Credentials` that is refused if group/other can read it. The first
  write records the choice in `<state>/credential-store`; the UI and service
  then always use it, with no later fallback. Force a store with
  `CONCLAVE_WORKSPACE_SECRET_STORE=secret-service|file`.
- **Process cleanup:** provider CLIs run in their own session/process group
  and are killed as a tree; the unit uses `KillMode=mixed` so anything left in
  its cgroup is reaped on stop.
- **Prevent sleep:** a logind `systemd-inhibit --what=sleep:idle` lock.

## Not yet qualified

Reboot/linger start, Secret Service on specific desktops, real provider
assignments, Wayland vs X11 sessions, and arm64 builds need device evidence.
