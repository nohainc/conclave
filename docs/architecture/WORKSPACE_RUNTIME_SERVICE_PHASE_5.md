# Workspace Runtime Service — Phase 5: Migration and release gates

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

**Status: in progress; not release-ready.** The standalone Dart service,
versioned local IPC backend, macOS bundle pipeline, runtime recovery, and
Flutter-to-service ownership handoff are implemented. The UI now sends
runtime-management commands through IPC and does not compose or start an
in-process runtime. Device-level launchd and end-to-end evidence are still
required before release.

## Existing installation data

The service uses the current Workspace Application Data directory and reads
the existing `workspace-registration.json`, `installation-id`, secure runtime
credential, Worker registry, Tool Profiles, Engine files, sessions, journal,
and Work Root in place. The runtime identity is not regenerated during normal
startup. No data-copy migration is needed for this layout, and a failed service
startup leaves those inputs untouched. The per-installation lock prevents the
service from starting a second runtime for the same installation.

The UI connects to the service using the versioned manager protocol, displays
its snapshots and events, and routes runtime operations through the manager.
It closes only its local IPC connection when the UI exits. Registration and
account ownership remain management actions in the UI and trigger an in-place
service configuration reload after local credentials and registration state
are updated.

## Packaging and development

`scripts/build-workspace-macos.sh` is the distribution build entry point. It
builds the Flutter application, compiles the standalone service, embeds the
service and generic CLI Worker Engine, includes the LaunchAgent plist, applies
the configured signing identity (or ad-hoc development signing), verifies the
bundle, and optionally notarizes the resulting archive.

For focused development, `scripts/run-workspace-service.sh` launches the Dart
service without building the Flutter app. It requires resolved Workspace
dependencies and the generic Engine. `scripts/check-workspace-service.sh`
compiles the service and runs its one-shot lifecycle in temporary Application
Data and Work Root directories. Workspace component CI invokes this check
after its regular analysis and tests.

## Validation groups

- Runtime unit tests cover Workspace lifecycle, assignment journal/recovery,
  credentials, registry, and Engine supervision.
- IPC tests cover version negotiation, authorization, commands, snapshots, and
  subscriptions. Local socket tests need a host that permits Unix sockets.
- Fixture end-to-end tests exercise Cloud assignment to Workspace and the
  generic Worker Engine. A release-host acceptance run must still prove that a
  request from AX executes while the Flutter management UI is closed.
- macOS integration validation must use a signed/notarized distribution build
  and test launchd registration, login startup, Keychain access, Work Root/TCC
  permissions, sleep/wake reconnect, upgrade recovery, and account ownership.

## Portability boundary

The runtime and local protocols are implemented in Dart and keep Cloud and
Worker behavior independent of Flutter and Apple frameworks. Service
registration is behind the Dart `WorkspaceServiceManager` interface. The
Flutter macOS adapter invokes the native `SMAppService` bridge; unsupported
platforms report that service management is unavailable instead of silently
claiming registration. Windows and Linux service adapters are intentionally
not implemented in this project.

The current manager transport is a permission-restricted Unix-domain socket;
`WorkspaceManagerService.start` explicitly rejects Windows. Windows Service
Control Manager and named-pipe adapters, and Linux systemd integration, remain
future work. A Windows implementation must decide whether a per-user agent is
more appropriate than a system service. A traditional Windows Service runs in
a different session/security context, so user-specific CLI credentials and
Work Roots cannot be assumed to be available. Credential Manager/DPAPI and
Linux secret-store integrations also remain future platform adapters.

Do not describe the full background-service product as cross-platform until
those service-manager, IPC, user-session, and credential boundaries have
implementations and tests.

## Remaining release blockers

1. Verify on a signed macOS host that AX Work executes while Workspace.app is
   closed and that reopening the UI restores the service's live state.
2. Exercise account changes, release/reset, and configuration reload under
   active and idle conditions; preserve current Workspace and runtime IDs and
   reject ownership changes until the old runtime is safely disconnected.
3. Define a Cloud-visible `outcome_unknown` recovery transition and a
   user-facing resolution path. The current service only exposes this state in
   its local manager snapshot.
4. Add macOS integration evidence for launchd, TCC, Keychain, reboot/login,
   update, and no-duplicate-runtime scenarios.
5. Update this status only after the release evidence is retained.

There is no database or Cloud protocol migration in this phase yet. Assignment
journal additions are backward-compatible optional result fields and local
recovery states; old terminal records remain readable.
