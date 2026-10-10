# Workspace Runtime Service — Phase 5: Migration and release gates

**Status: in progress; not release-ready.** The standalone Dart service,
versioned local IPC backend, macOS bundle pipeline, and runtime recovery are
present. The Flutter management UI still owns and starts an in-process runtime,
so migration to service ownership and removal of the legacy UI runtime are not
complete.

## Existing installation data

The service uses the current Workspace Application Data directory and reads
the existing `workspace-registration.json`, `installation-id`, secure runtime
credential, Worker registry, Tool Profiles, Engine files, sessions, journal,
and Work Root in place. The runtime identity is not regenerated during normal
startup. No data-copy migration is needed for this layout, and a failed service
startup leaves those inputs untouched. The per-installation lock prevents the
service and UI runtime from executing concurrently.

The lock is only a safety barrier, not a completed ownership transfer. The UI
does not attach to the service after a lock conflict, display its state, or
route management commands through IPC. Do not enable the LaunchAgent as the
normal product runtime until that handoff is implemented and tested.

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
  generic Worker Engine. They do not yet prove that a request from AX executes
  while the Flutter management UI is closed.
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

1. Make Flutter Workspace an IPC client and remove its in-process Cloud,
   Worker Engine, readiness, reconnect, and assignment lifecycle ownership.
2. Make Connect, Disconnect, sign-in, sign-out, owner changes, Worker
   configuration, diagnostics, and shutdown use the service boundary. Preserve
   the current Workspace and runtime IDs and reject account changes until the
   old runtime is safely disconnected and ownership is verified.
3. Define a Cloud-visible `outcome_unknown` recovery transition and a
   user-facing resolution path. The current service only exposes this state in
   its local manager snapshot.
4. Add macOS integration evidence for launchd, TCC, Keychain, reboot/login,
   update, and no-duplicate-runtime scenarios.
5. Only after the handoff passes, delete the old Flutter-owned runtime
   composition and update this status to complete.

There is no database or Cloud protocol migration in this phase yet. Assignment
journal additions are backward-compatible optional result fields and local
recovery states; old terminal records remain readable.
