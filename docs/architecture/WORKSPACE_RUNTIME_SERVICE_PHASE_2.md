# Workspace Runtime Service — Phase 2

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

**Status:** Workspace.app is a service manager and authenticated IPC client.

## Management boundary

The Workspace page has two independent sections:

- **Workspace Service** shows host registration, process state, PID, version,
  start time, and IPC readiness. Register, unregister, start, stop, and restart
  are host-management operations handled by the macOS service manager.
- **Conclave Cloud** shows the Cloud connection state, effective Workspace, and
  transport. Connect, disconnect, and reconnect are runtime commands sent over
  authenticated Workspace Manager IPC.

Cloud controls remain informational while the service is stopped or while IPC
is unavailable. Starting the local service does not implicitly connect Cloud;
the service restores its persisted Cloud intent, and an explicit Cloud action
uses the IPC command boundary.

## IPC ownership

Workspace.app does not access runtime objects, Worker registries, Cloud
transports, or reconnect policy directly. Worker inventory, Worker setup and
testing, configuration reads/reloads, assignment controls, logs, metrics, and
diagnostics use the versioned authenticated Unix-domain socket protocol.

The host manager is deliberately separate because IPC cannot start a process
that is not running. This gives the UI precise states such as:

```text
Registered · Stopped · IPC unavailable
Registered · Running · IPC ready
Registered · Failed · IPC unavailable
```

The service remains the only owner of Cloud and Worker runtime state after its
process starts. Closing Workspace.app only closes its IPC client.
