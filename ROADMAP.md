# Conclave AX Roadmap

Architecture v6 is the historical Workstream/filesystem baseline. Architecture
v7 is the active Worker/runtime architecture. Its desktop vertical slice and
V6 compatibility retirement are implemented; production release gates remain
open before v7 becomes the declared implemented baseline.

Current execution direction:

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> local Worker -> adapter process
```

Projects are the collaboration boundary. Workspaces provide machine execution.
Configured Workers are created/authenticated locally in Conclave Workspace,
belong to exactly one Workspace, and synchronize only safe inventory/readiness
to Cloud. Workers never connect directly to Conclave Cloud.

The first-party v1 product catalog is frozen by
[ADR-015](docs/decisions/ADR-015-first-party-worker-v1-contract.md): exactly
one ChatGPT slot backed by Codex CLI and one Gemini slot backed by Antigravity
CLI per Workspace. Provider login, credential storage, and subscription/API
billing mode remain owned by the corresponding local CLI. Existing broader
adapters and multi-instance records require a later migration phase and are not
part of the v1 product catalog.

## Active work

The detailed architecture roadmap is:

[Architecture v7 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V7_IMPLEMENTATION.md)

The ordered remaining work and release gates are:

[Architecture v7 Completion Plan](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)

The current implementation audit is:

[V7 Implementation Audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)

Phases 1–3 are implemented: Cloud-owned V7 scheduling state and inventory,
real V7 end-to-end assignment execution, and retirement of V6 Worker
compatibility APIs, scheduler fallback, and persistence.

Phase 4's Ed25519 trust and first-party release workflows are implemented. The
remaining release sequence is:

1. **Phase 5:** finish supported-catalog and real-provider acceptance;
2. **Phase 6:** close operational failure/recovery/security acceptance;
3. **Phase 7:** finish the native `.app` replacement/restart/health-check/rollback transaction;
4. **Phase 8:** keep documentation aligned now; declare v7 the implemented
   baseline only after every release gate passes.

The Phase 2 behavioral E2E migration-safety gate passes and remains a regression test for the V7 execution path.

## Historical roadmaps

Earlier implementation history remains available in:
- [Architecture v5 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)


## Workspace desktop authentication and transport resilience

ADR-013 defines the next Workspace product evolution: Conclave Workspace gains
human sign-in for local ownership/management, desktop-owned Workspace
registration/recovery, WebSocket as the preferred runtime transport, and HTTPS
long-poll as a functional fallback. Conclave AX Workspaces becomes read-only
for machine/runtime and local Worker operational state; Project/Workstream
collaboration and authorization remain in AX/Cloud.

Implementation sequence:

[Workspace Desktop Authentication and Dual-Transport Implementation](docs/roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md)

ADR-014 refines the desktop lifecycle after the first ADR-013 implementation: human Sign in no longer implies runtime connection, signed-out/locked shells hide management controls, connected runtimes auto-start/reconnect after OS login, and account switching requires explicit disconnect/release ownership.

ADR-014 Phase 0 lifecycle types are defined in the host protocol package and
mirrored in the desktop runtime. Human authentication, runtime participation,
management lock, desired runtime intent, and transport projection remain
independently constructible; non-secret local preferences have a strict shape.

Phase 1 separates browser sign-in from Workspace registration: sign-in stores
and displays the desktop account only. **Connect Workspace** explicitly
confirms the machine name, registers or recovers under that account, verifies
the returned owner, stores runtime intent/credential, starts the runtime, and
exposes Worker management only after the runtime reaches Ready.

Phase 2 routes the app window through a minimal signed-out shell until the
stored desktop human session is both unexpired and server-validated. A paired
runtime whose session needs reauthentication shows a dedicated sign-in shell
while its runtime lifecycle remains independent. The root-shell UI test checks
that signed-out users cannot see Workspace, Workers, Work Root, or lifecycle
management actions.

Phase 3 now requires owner reauthentication for Disconnect and Reset, confirms
Disconnect, preserves the installation ID and owner binding on Disconnect and
Reset, persists disconnected runtime intent, and makes connected Sign out an
explicit Disconnect and sign out choice. Reset's warning enumerates the local
registration, runtime identity, Worker/provider credential, adapter, and human
session data it removes while preserving Work Root files and installation
ownership; a Cloud revocation failure stops the reset. Disconnect drains active
assignments before Cloud revocation. The advanced Release action now has a
separate fresh-owner-authenticated Cloud endpoint, active-assignment gate, audit
event, runtime revocation, ownership unlink, and local preservation flow. macOS
13+ Connect offers an explicit launch-at-login choice backed by
`SMAppService.mainApp`.

Disconnected installations retain the non-secret local registration and cached
owner metadata so Release remains available after Disconnect. Startup honors
`desiredRuntimeState = disconnected` and suppresses runtime connection from that
registration until the owner explicitly reconnects.

Phase 4 adds a Cloud ownership-check endpoint used before desktop sign-in
replaces an existing human session. Both that check and registration/recovery
reject a different authenticated user with `installation_already_owned` before
rotating credentials or changing bindings. Legacy registrations can be linked
to their persistent installation ID only after Cloud verifies the same owner;
desktop caches the confirmed owner only after that check. Ownership checks also
reject mismatched installation IDs and mixed Workspace/runtime bindings, even
when the authenticated user owns each record, so stale or altered local IDs
cannot authorize an account transition. The desktop keeps management surfaces
hidden when the stored session user differs from the Cloud-confirmed owner.

Phase 5 restores desktop human sessions asynchronously after the runtime has
started. Still-valid sessions nearing expiry rotate in place and persist the
replacement credential; revoked/expired sessions route to sign-in when
disconnected or same-owner reauthentication when the runtime is intended to
remain connected. Reauthentication replaces the desktop session without
re-registering or rebuilding the runtime, and passive expiry never disconnects
Cloud participation.

[Workspace Desktop Lifecycle Implementation](docs/roadmaps/WORKSPACE_DESKTOP_LIFECYCLE_IMPLEMENTATION.md)
