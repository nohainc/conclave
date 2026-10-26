# Workspace on Linux

Linux x64/arm64 source support includes the Flutter management UI, the
standalone Dart Workspace Service, and the separately supervised generic CLI
Worker Engine (ADR-021). Desktop tarballs remain unsigned candidates. The headless service, management
CLI and Engine can also be shipped together as a Debian package through a
signed APT repository. See [Linux release operations](../deployment/WORKSPACE_LINUX_RELEASES.md)
for publication setup and qualification requirements.

## Install the headless Debian package

Use the production HTTPS repository below. Verify the public signing key against
fingerprint `6EA013D12EF79CBDC34D66058182CCCFCF4175F2` before installing it.

```bash
APT_URL=https://nohainc.github.io/conclave
curl --fail --location "$APT_URL/conclave-archive-keyring.gpg" -o /tmp/conclave-archive-keyring.gpg
gpg --show-keys --with-fingerprint /tmp/conclave-archive-keyring.gpg
sudo install -D -m 644 /tmp/conclave-archive-keyring.gpg /etc/apt/keyrings/conclave-archive-keyring.gpg
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: /etc/apt/keyrings/conclave-archive-keyring.gpg\n' "$APT_URL" | sudo tee /etc/apt/sources.list.d/conclave.sources
sudo apt update
sudo apt install conclave-workspace
```

Run all following commands as the normal user who owns the provider CLI logins,
without `sudo`. The package does not install provider CLIs or manage their logins.
It installs binaries under `/usr/lib/conclave-workspace`, and symlinks under
`/usr/bin`; GTK and a desktop session are not needed.

```bash
conclave-workspace setup
# Enter your existing Conclave Cloud email and password at the prompts.
# Password input is hidden. Never pass it as a command-line argument.
conclave-workspace status
sudo loginctl enable-linger "$USER"
```

`setup` registers/enables and starts the systemd **user** service, waits for
authenticated local IPC, signs in through Cloud's existing Better Auth
email/password verifier, registers or recovers this installation, and waits for
Cloud synchronization. It never installs or probes Workers. Zero Workers is a
supported online state. Already registered installations reconnect without
asking for a password. The runtime credential persists across logout and service
restart; it is independent of the management session's expiry. No browser is
needed on the server and no public inbound port is opened.

For an already running service, `conclave-workspace login --password` performs
only account sign-in/registration; follow it with `conclave-workspace connect`.
Accounts that require additional verification must use the existing browser
flow (`conclave-workspace login`, opening the returned URL on another device).
Password sign-in does not bypass MFA, disabled accounts or ownership checks.
Passwords and temporary authentication cookies are never stored in Workspace
state, CLI output or diagnostics. The temporary Cloud login session is closed
after issuing the separate desktop management session.

Before contacting Cloud, login tests credential write/read/delete. A fresh
Linux install selects Secret Service only when both `secret-tool` and an active
`org.freedesktop.secrets` service are available. A systemd user D-Bus by itself
does not qualify. Otherwise it selects the documented headless file store:
`0700` directory and `0600` files owned by the service user. An existing recorded
store remains authoritative; it is never silently replaced. If it is broken,
setup fails before remote registration. Review the recorded store and preserve
existing keys before any explicit repair.

Login failures report a safe `stage` and `code` through `login status`, without
returning server response text or secrets. A Cloud-only registration can be
recovered under the same installation identity after same-owner verification;
setup does not create a replacement Workspace to conceal a failed local write.

Browser `login` starts a service-owned approval operation and returns immediately. Poll
`login status` for `pending`, `complete`, `failed` or `cancelled`; use
`login cancel` to cancel before registration commits. No comparison code is
printed because the existing Cloud approval contract uses a verification URL.
The service retains the intent poll token, human session and runtime credential;
none is returned to the CLI. Sign-in refuses a different owner or ambiguous/stale
registration; existing installations needing recovery must use the desktop
recovery flow. A fresh registration does not connect Cloud until `connect`.

The service uses the default Linux Work Root (`~/Documents/Conclave`) unless
configured otherwise. For a custom Work Root, use the foreground service with
`--work-root /absolute/path` under your own supervisor, or configure the persisted
Work Root through the desktop manager before using the systemd unit.
Pass `--data-dir DIR` on **every** CLI command when using a custom state root.
`service install` registers/enables the systemd user unit but does not start it.
`service stop` preserves its registration; `service uninstall` removes the user
unit and preserves all user files.

Update after active assignments finish:

```bash
conclave-workspace service stop
sudo apt update
sudo apt install --only-upgrade conclave-workspace
conclave-workspace service start
conclave-workspace health
```

APT updates the complete service/CLI/Engine unit. Package installation, upgrade,
removal and purge have no maintainer scripts that start a root service or alter
user state. A running daemon is not automatically restarted: stop/start it as
shown so it uses the matching new Engine. This package disables the separate
application self-updater; APT owns updates. Automatic upgrades require explicitly
configuring the host's unattended-upgrades origin and an appropriate maintenance
window. Removing the package leaves user service registration and state in place;
run `service uninstall` first if you want to remove its systemd unit too.

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
(`~/.claude`, `~/.codex`, `~/.gemini`) on volumes.

Manage a running service with `conclave-workspace` (ADR-021 §2.6). It speaks
the local authenticated IPC only; pass `--data-dir` if the service did:

```bash
./conclave-workspace status          # also: health, version, metrics, logs
./conclave-workspace connect         # disconnect, pause, resume
./conclave-workspace workers         # workers check|test|enable|disable
./conclave-workspace slots           # assignments, assignments cancel ID, folders
```

Add `--json` for raw output. Use `login`, `login status` and `login cancel`
for initial Cloud registration through browser approval. A foreground process
can use these commands without systemd; its supervisor owns process lifecycle.

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
assignments, Wayland vs X11 sessions, and ARM64 desktop UI startup need
device evidence. Headless amd64/arm64 package lifecycle checks are documented
in [Linux package acceptance](../acceptance/WORKSPACE_LINUX_PACKAGES.md).
