# ADR-021: Workspace Service on Linux and Windows

**Status:** Accepted
**Date:** 2026-10-20
**Builds on:** [ADR-012](ADR-012-workspace-owned-local-workers.md), [ADR-014](ADR-014-workspace-desktop-lifecycle.md), [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md), [Workspace architecture](../architecture/WORKSPACE_ARCHITECTURE.md)
**Normative for:** `WorkspaceServiceManager` platform adapters, Workspace Service platform seams (paths, secret store, IPC transport, lock), CLI Worker Engine process supervision, and Linux/Windows build artifacts.

## 1. Context

The headless Dart Workspace Service is platform-independent, but only a macOS
launchd adapter, Unix-socket IPC, and Keychain secret store exist. Linux and
Windows were explicitly out of scope until requested, with the Windows
user-session and CLI-credential ownership questions left open. Users now want
to run Workspace on a Linux mini PC, on headless Linux hosts such as Fly
Machines or containers, and on Windows.

Provider CLIs (Claude Code, Codex, Gemini/AGY) authenticate through
subscription logins stored in the user's home directory (`~/.claude`,
`~/.codex`, `~/.gemini`, and platform equivalents). Syntila never manages
provider credentials (ARCHITECTURE_V8), so whichever account runs the Worker
Engine must be the account that logged in to the CLIs.

## 2. Decision

### 2.1 Platform matrix

| Platform | Host registration | Mode |
| --- | --- | --- |
| macOS | launchd LaunchAgent (existing) | per-user, at login |
| Linux desktop/server | **systemd user unit** (`~/.config/systemd/user/`) | per-user; `loginctl enable-linger` for start at boot without a session |
| Linux headless/container | none — service is the foreground main process | `workspace --data-dir /data/state`; the container/supervisor owns restarts |
| Windows | **per-user logon task** (Task Scheduler, "at logon", run only when user is logged on, no elevated rights) | per-user, in the interactive user session |

Windows Service Control Manager (LocalSystem or a virtual service account) is
**rejected**: it would not see the user's CLI logins or profile, would need a
separate credential-ownership story, and would cross a privilege boundary the
Service does not need. A system-level systemd unit is likewise not the default.

### 2.2 Credential ownership

- The Service, the Worker Engine, and provider CLIs all run as the same
  logged-in OS user. Syntila never copies, proxies, or stores provider CLI
  credentials.
- Provider credential directories must be persistent. Headless/container
  deployments must mount the user's home (or the CLI credential directories)
  and Application State on persistent volumes; ephemeral filesystems are an
  unsupported configuration that the Service reports as a readiness failure
  rather than silently re-prompting.
- The Workspace runtime credential (Cloud identity) is held in the platform
  secret store below, never in application tables or plaintext config.

### 2.3 Secret store

Linux auto-selection requires an installed `secret-tool` and a running Secret
Service owner on the user bus. A headless systemd bus alone is insufficient.
The recorded store remains authoritative; setup validates private credential
write/read/delete before contacting Cloud and never silently changes an existing
store. Headless `setup` uses the same Cloud email/password verifier as AX,
through a scoped desktop-session exchange; password input remains ephemeral.
Accounts requiring additional verification retain the browser fallback.

| Platform | Store |
| --- | --- |
| macOS | Keychain (existing) |
| Linux desktop | Secret Service (libsecret) when a session bus is available |
| Linux headless | `systemd-creds` encrypted credential when available, otherwise a `0600` file owned by the user under the state directory; the Service refuses to start if permissions are broader |
| Windows | DPAPI (`CurrentUser` scope) protected blob under the state directory; Credential Manager is acceptable but not required |

Selection is explicit and recorded in configuration; there is no silent
fallback from an unavailable secure store to a weaker one on desktop
platforms.

### 2.4 Local IPC

The protocol (versioning, capability-key authentication, frame bounds,
snapshot then events) is unchanged. Only the transport is per-platform:

- macOS/Linux: Unix-domain socket in a `0700` runtime directory
  (`$XDG_RUNTIME_DIR/syntila-workspace/` on Linux).
- Windows: named pipe `\\.\pipe\syntila-workspace-<installation-id>` with a
  DACL granting only the owning user SID; remote clients are rejected
  (`PIPE_REJECT_REMOTE_CLIENTS`).

IPC is never a TCP/localhost listener.

### 2.5 State locations

| Platform | Runtime state root |
| --- | --- |
| macOS | `~/Library/Application Support/Syntila/Workspace/` (existing) |
| Linux | `$XDG_STATE_HOME/syntila/workspace/` (default `~/.local/state/...`) for registry, sessions, logs, runtime; `$XDG_DATA_HOME/syntila/workspace/` for Profiles and Engines; `$XDG_CACHE_HOME` for cache |
| Windows | `%LOCALAPPDATA%\Syntila\Workspace\` |

Work Root remains user-chosen (default `~/Documents/Syntila` or
`%USERPROFILE%\Documents\Syntila`; headless hosts must set it explicitly).
`SYNTILA_WORKSPACE_DATA_DIR` keeps its existing override semantics.

### 2.6 Headless management

Hosts are managed through a small
`syntila-workspace` command-line client that speaks the same authenticated
IPC protocol (status, connect/disconnect Cloud, start/stop, Worker list and
verification, logs). It does not spawn Engines or provider CLIs and does not
talk to Cloud directly; the Service remains the only owner. Initial Cloud
registration on a headless host uses the existing device-authorization flow
rendered as a URL/code in the terminal.

### 2.7 Engine process supervision

The Engine stays a separately supervised child. On Windows the Engine places
provider CLI processes in a Job Object (kill-on-close) instead of a POSIX
process group, uses `TerminateJobObject` for forced cleanup after a graceful
CTRL_BREAK/close attempt, resolves executables with `PATHEXT` (including
`.cmd`/`.bat` shims, invoked safely without shell interpolation of arguments),
and tolerates CRLF in line-delimited protocol output.

### 2.8 Lock

The per-installation lock remains the duplicate-owner guard on every
platform, implemented with an exclusive OS file lock in the state root
(`flock` on POSIX, `LockFileEx` on Windows).

## 3. Phasing

0. This ADR and architecture update.
1. Platform seams: paths, secret store, IPC transport, and lock behind
   injected interfaces; shared runtime has no macOS-only imports; Engine
   Windows supervision.
2. Linux: systemd user adapter, foreground mode, `syntila-workspace` CLI,
   Linux x64/arm64 artifacts, container/Fly template.
3. Windows: logon-task adapter, named-pipe IPC, DPAPI store, artifacts.
   Installer packaging and code signing are a later, separate phase.
4. ~~Optional Flutter Workspace UI on Linux/Windows.~~ Superseded: the Flutter
   Workspace UI was removed on every platform; the CLI is the management client.
5. Tool Profile CLI path/argument verification on Linux/Windows.

## 4. Consequences

- Existing macOS installations are unchanged: installation ID, Cloud Workspace
  and runtime IDs, secure credential, Work Root, registry, Profiles, Engines,
  and sessions are preserved. New platforms are fresh installs; no migration.
- `service stop` keeps registration and `disconnect` keeps the process
  running on every platform.
- A Workspace on a headless host only works for CLIs that were logged in on
  that host as the service user.
- Claims such as "survives reboot", "credentials persist", or "pipe is
  user-only" require device evidence on the target OS, not only unit tests.
