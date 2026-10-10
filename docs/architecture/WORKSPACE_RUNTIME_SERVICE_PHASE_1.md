# Workspace Runtime Service — Phase 1

**Status:** Headless runtime and Flutter IPC management ownership implemented.

## Existing ownership audit

| Responsibility | Current implementation owner |
| --- | --- |
| Sign-in, account forms, Worker configuration, settings, status display | Flutter Workspace UI in `apps/workspace/lib/main.dart` and its `main/` parts |
| Secure credentials | Dart runtime credential store in `secure_credentials.dart`; macOS UI authentication bridge remains in `secure_credentials_flutter.dart` |
| Cloud WebSocket, fallback, reconnect, registration, heartbeats, inventory and assignment protocol | `WorkspaceCloudConnection` and runtime composition |
| Worker catalog synchronization and readiness | `WorkerCatalogCoordinator` and `WorkerReadinessMonitor` |
| Engine process lifecycle, assignment handling/cancellation, sessions and diagnostics | Workspace runtime and the separate CLI Worker Engine process |
| Work Root and Space working-directory resolution | Workspace runtime configuration and `SpaceDirectoryLifecycle` |
| Service process entry | `apps/workspace/bin/conclave_workspace_service.dart` |

The Worker Engine remains a separate child process. It does not own the Cloud
connection and does not receive the Workspace runtime credential.

## Implemented boundary

The standalone service entry composes the existing Dart runtime without
importing Flutter APIs. Release-mode selection, catalog listeners, and bundled
Engine loading now use Dart-only seams. The runtime can therefore be compiled
as an executable with the resolved Workspace package configuration:

```sh
bash scripts/build-workspace-service.sh
```

The service retries initial Cloud failures with bounded backoff while keeping
the local runtime process alive. `workspace-state.json` now records process
state, Cloud connection state, execution state, active assignment count, and
installation identity independently. The per-installation advisory lock is
held for the process lifetime; the operating system releases it when the
process exits unexpectedly.

## UI/service ownership handoff

The Flutter shell now creates only its local management configuration and
connects to `WorkspaceManagerIpcConnection`. It does not compose, start, stop,
or reconnect a Workspace runtime. Closing or quitting the UI closes only its
IPC client; the separately managed service keeps its Cloud connection and
assignments. Runtime status and Worker catalog state are driven by the service
snapshot and events.

Cloud connection control, readiness checks, Worker setup/activation/profile actions,
diagnostics and runtime configuration reloads use the
versioned IPC boundary. Sign-in and Cloud ownership operations remain
management actions in the UI; after they update shared secure/local
configuration, they ask the service to reload while preserving installation
and runtime identities. The UI no longer writes the Worker registry directly.
Existing Cloud and Worker protocols are unchanged.

## Local management IPC

The service exposes the versioned request/response and event protocol through
`workspace_manager_ipc.dart`. It uses a Unix-domain socket below the private
Workspace Runtime directory, a 0700 parent directory, a 0600 socket, and a
0600 per-installation capability key. The protocol negotiates a version before
accepting commands, limits frames to 1 MiB, correlates responses by request ID,
and sends an initial status snapshot followed by subscribed runtime events.
Clients reconnect with bounded backoff after a service restart.

The command dispatcher provides status/version/health, connect, disconnect
with a 15-second assignment drain, reconnect, Worker catalog and registry
operations, readiness/profile actions, active assignment list/cancel,
configuration read/update/reload, diagnostics, metrics, and bounded log-tail
commands. Service restart and shutdown explicitly require the host-management
boundary.

The socket and protocol tests are present. In restricted execution environments
that deny local socket creation they report as skipped; they must run on a
normal Workspace development host before this transport is considered verified.

The ownership boundary is implemented in code. Signed macOS bundle, launchd,
TCC, Keychain, reboot/login, and Cloud-to-Worker end-to-end validation remain
release evidence; this implementation has not established those device-level
claims.

## Lifecycle dimensions

`workspace-state.json` separates:

- process state: starting, initializing, ready, stopping, stopped, or failed;
- Cloud state: not configured, authentication required, disconnected,
  connecting, connected, or reconnecting;
- execution state: idle or executing.

An offline Cloud connection does not mean the service process has failed.

## Service controls and display cache

Workspace.app exposes Start Service / Stop Service using the host manager.
`service.prepareStop` is an additive IPC command: it pauses assignment admission,
drains for the existing bounded grace period, and closes Cloud transport. A
failed drain resumes admission and reports `assignments_active`; process
termination remains exclusively a host-management operation. The UI verifies
IPC disconnect before reporting a successful stop. Start enables login startup;
Stop disables it. macOS approval-required responses identify Login Items.

UI snapshots expose service process state separately from Cloud connection.
The app does not own a Cloud execution WebSocket or HTTP fallback client.
Worker tests execute through IPC with a bounded response timeout. The local
`runtime/manager-worker-display.json` projection is a best-effort display cache,
never an authority for Worker configuration or assignment admission. Cached
controls are disabled while the service is stopped.

Runtime executables are named `conclave-service` and `conclave-agent`. The
service LaunchAgent label and installation identity are unchanged. Shared
bundled Engine asset names are unchanged; Workspace materialization assigns
the process name. Existing independent legacy daemons are not managed here.

Work Root selection while stopped is persisted by `StoppedWorkspaceConfiguration`
in the existing local lifecycle preferences file. It validates path separation
and access under the same installation lock used by the service. The GUI cannot
change Work Root through a running service; `configuration.update` rejects that
operation. Configuration is read at startup, requires no Cloud round trip, and
does not move files. IPC startup and configuration reload do not await Cloud
connectivity. A slow/offline Cloud handshake does not block local management.

## IPC startup reliability

Flutter disposes failed initial manager clients and subscriptions, including
their reconnect loop, before permitting a fresh attachment attempt. A single
in-flight attempt prevents duplicate management clients. Retries reread the
capability key; established IPC connections retain their existing reconnect
behavior. Startup timeout means local attachment failed, not proof of process
failure. Sanitized host status and IPC diagnostics remain visible in the
management UI. Regression tests use real Unix sockets for delayed key/socket
readiness, rejected handshakes, concurrent starts, timeout, and attaching to an
already running service without re-registering it.
