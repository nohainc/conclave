# Workspace Runtime Cleanup — Phase 1

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

This phase makes the Workspace Service boundary explicit before additional
runtime features are added. The headless service owns Cloud transport, Worker
inventory/readiness, Worker Engine supervision, assignments, sessions, journals,
diagnostics, and runtime state. Workspace.app owns authentication and
configuration UI, native service registration/process control, IPC, and status
presentation.

## Ownership inventory

| Area | Owner | Boundary |
| --- | --- | --- |
| Authentication and account ownership | Workspace.app | Browser sign-in and registration commands; credentials remain in secure storage |
| Service registration/process control | Native `WorkspaceServiceManager` | Register, unregister, start, stop, restart, PID and launch diagnostics |
| Runtime state and execution | Workspace Service | `WorkspaceRuntime`, Cloud connection, assignments, journals, sessions, Worker Engine children |
| Worker configuration and readiness | Workspace Service | Local registry, catalog/Profile resolution, readiness probes, enable/disable/test |
| UI runtime projection | Workspace.app | Authenticated versioned IPC snapshots/events only while the service is running |
| Filesystem state | Workspace Service | Application Data, Work Root and Space directory resolution |
| Compatibility and migration | Explicit stores/adapters | Retained only where needed to read existing installations or protocol payloads |

## Source layout

The runtime root is `WorkspaceRuntime` in `workspace.dart`, constructed by
`buildWorkspaceRuntime` in `workspace_runtime.dart`. `WorkspaceManagerService`
is the IPC server around that runtime; it does not execute work itself.

Configuration resolution is centralized in
`WorkspaceConfigurationResolver`. It reads command-line overrides, environment
values, registration, lifecycle preferences and secure credentials once and
returns `ResolvedWorkspaceConfiguration`. Runtime components receive the
resolved `WorkspaceConfig` instead of rereading those sources.

Lifecycle facts use three independent dimensions in
`workspace_service_lifecycle.dart`:

```text
ServiceInstallationState  registration with the host service manager
ServiceRuntimeState       local process state
CloudConnectionState      service-to-Cloud transport state
```

IPC readiness is a health property. `serviceHealthy`, `canConnect`, and
`canManageWorkers` are derived from runtime state and IPC readiness; they are
not persisted as independent lifecycle state.

## Transitional code policy

- **Keep:** registration and lifecycle file readers that preserve existing
  Workspace identity, runtime credentials, Work Root, Worker registry, Profiles,
  Engine files and sessions.
- **Keep:** wire-compatible IPC fields while clients update to the explicit
  lifecycle dimensions.
- **Delete when the next protocol/client cutover lands:** the `Workspace` type
  alias, legacy lifecycle JSON key, and duplicate UI-only status projections.
- **Delete now:** no UI path may create Cloud connections, start Worker Engine
  processes, execute readiness checks, or use runtime files as an IPC fallback.

The per-installation lock remains the final duplicate-owner guard. No second
runtime is started during configuration reload or UI reconnect.
