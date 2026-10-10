# Workspace Runtime Service — Phase 1

**Status:** Headless service and local IPC backend implemented; GUI ownership
handoff remains incomplete.

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

## Remaining handoff

The Flutter shell still constructs the runtime in `main/app.dart`, starts it
from `WorkspaceLifecycleController.launch`, requests readiness/reconnect work
from `didChangeAppLifecycleState`, and stops it from `dispose`/`quit`. Workspace
management forms also currently call runtime controllers directly. The shell
has not yet become a client of the standalone process, so closing the Flutter
process does not yet leave a separately launched service behind.

Completing that handoff requires a versioned local management protocol and
moving runtime mutations behind it. The protocol backend is now present, but
the desktop app does not yet connect to it or delegate its runtime to it. The
standalone executable is usable independently for headless operation. Existing
Cloud and Worker protocols are unchanged.

## Local management IPC

The service exposes the versioned request/response and event protocol through
`workspace_manager_ipc.dart`. It uses a Unix-domain socket below the private
Workspace Runtime directory, a 0700 parent directory, a 0600 socket, and a
0600 per-installation capability key. The protocol negotiates a version before
accepting commands, limits frames to 1 MiB, correlates responses by request ID,
and sends an initial status snapshot followed by subscribed runtime events.
Clients reconnect with bounded backoff after a service restart.

The command dispatcher currently provides status/version/health, connect,
disconnect with a 15-second assignment drain, reconnect, Worker list/enable/
disable/live test, active assignment list/cancel, configuration read,
diagnostics, metrics, and bounded log-tail commands. Service restart and
shutdown explicitly require the host-management boundary. Runtime
configuration updates are not yet supported by IPC.

The socket and protocol tests are present. In restricted execution environments
that deny local socket creation they report as skipped; they must run on a
normal Workspace development host before this transport is considered verified.

The Flutter UI has not yet been migrated to `WorkspaceManagerIpcConnection`.
Until that migration is complete, it still starts and stops the in-process
runtime, reads live runtime objects directly, and does not receive these IPC
events. Consequently closing the UI does not yet leave the runtime running
independently through the desktop product flow.

## Lifecycle dimensions

`workspace-state.json` separates:

- process state: starting, initializing, ready, stopping, stopped, or failed;
- Cloud state: not configured, authentication required, disconnected,
  connecting, connected, or reconnecting;
- execution state: idle or executing.

An offline Cloud connection does not mean the service process has failed.
