# Conclave AX Roadmap

Architecture v8 is the active implementation target.

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

Architecture v8 preserves the v7 Workspace ownership model and current Work v1
product, but replaces separate provider-specific native Worker executables with
one generic CLI Worker Engine and immutable signed Tool Profiles.

## Current product contract

Work v1 remains constrained and product-owned.

Canonical Steps:

~~~text
Research
Plan
Implement
Test
Verify
~~~

Built-in Workflows:

~~~text
Direct
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Workstreams bind logical Workers to Direct/Steps. Work Requests snapshot
Workflow, Worker/model bindings, instructions, attachments, and internal Step
Prompt Profile versions.

The runtime change is below that logical Worker boundary:

~~~text
Implement -> ChatGPT
               |
               v
        CLI Worker Engine
               |
       chatgpt-codex@N
               |
               v
             codex
~~~

## Architecture v8 active work

The authoritative implementation sequence is:

[Architecture v8 Implementation Plan](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)

Core v8 contracts:

- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)

The implementation order is intentionally:

1. freeze/machine-validate Tool Profile v1;
2. implement the constrained Profile interpreter;
3. implement Local Worker Protocol 4.0;
4. build one generic Dart CLI Worker Engine;
5. add Cloud Profile definitions/releases/lifecycle/trust;
6. add Workspace Profile cache/resolver/activation;
7. port current ChatGPT behavior to `chatgpt-codex` Profile;
8. port current Gemini behavior to `gemini-antigravity` Profile;
9. pass real provider and Work v1 acceptance;
10. add testing/beta/stable Profile promotion and rollback;
11. remove separate provider-specific Worker binaries/release paths;
12. converge DB/docs and prove a third CLI can be added profile-only.

## v8 success criterion

A normal supported provider CLI compatibility change should usually be handled
as:

~~~text
new immutable Profile release
-> fixture tests
-> Testing
-> real provider acceptance
-> Stable
~~~

without:
- rebuilding Conclave Workspace;
- rebuilding a provider-specific Worker executable;
- changing Workstream bindings.

## Current implementation baseline

Main already contains:
- v7 Workspace-owned local Worker execution;
- Dart Worker Runtime v2 process/protocol primitives;
- real local ChatGPT/Gemini Worker implementations;
- constrained Work v1 Steps/Workflows;
- server-backed Work history and multi-step handoff behavior.

Those implementations are migration references for v8.

Do not remove current provider-specific Dart Workers until generic Engine/Profile
acceptance passes for both providers.

Do not add new normal provider-specific Worker executables during the v8
migration.

## Profile release lifecycle

Official v8 Profiles are Conclave-controlled:

~~~text
Draft
-> Testing
-> Beta (optional)
-> Stable
-> Retired / Revoked
~~~

Profile payloads are immutable and signed.

Normal users do not edit/create Profiles in v8.

Workspace keeps active and last-known-good verified Profile releases so a broken
Profile can be rolled back without an application update.

## Version layers

Operational evidence must distinguish:

~~~text
Workspace version
CLI Worker Engine version
Tool Profile definition/release
provider CLI version
provider model when explicit
~~~

This distinction is central to diagnosing compatibility failures.

## Historical architecture

Architecture v7 and Worker Runtime v2 remain valuable predecessor documentation
for:
- Workspace ownership;
- process isolation;
- provider credentials staying local;
- process-tree supervision;
- durable session mapping.

ADR-017 is superseded by ADR-018 for first-party CLI implementation.

The v7 completion/implementation roadmaps are no longer the active place to
schedule new runtime work. Open v7 production/recovery concerns that still
apply must be carried into the relevant v8 phases rather than extending the
per-provider binary architecture.

## Historical roadmaps

Earlier implementation history remains available in:
- [Architecture v5 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V5_IMPLEMENTATION.md)
- [Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)
- [v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)


## Worker Runtime v2 — standalone Dart Worker executables

ADR-017 keeps Architecture v7 but replaces the legacy Node-backed first-party
Worker runtime with independently versioned native Dart console executables:

~~~text
Conclave Workspace
-> ChatGPT Worker executable -> Codex CLI

Conclave Workspace
-> Gemini Worker executable -> agy
~~~

Workspace owns Worker installation, signature verification, activation, update,
rollback, process supervision and Local Worker Protocol. Each Worker owns
provider CLI discovery, version/auth checks, execution, session IDs, output
parsing and provider-specific diagnostics.

This is intentionally an aggressive pre-production convergence: after both Dart
Workers and update/rollback acceptance pass, the legacy Node `.mjs` adapters, Node
runtime prerequisite, legacy release schema, obsolete local Worker
fields, and unreleased D1 compatibility layers should be removed rather than
maintained indefinitely.

Implementation sequence:

[Worker Runtime v2 Implementation Plan](docs/roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md)

Architecture contract:

[Worker Runtime v2](docs/architecture/WORKER_RUNTIME_V2.md)

Decision:

[ADR-017: Standalone Dart Worker Executables](docs/decisions/ADR-017-standalone-dart-worker-executables.md)

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
registration, runtime identity, Worker/provider credential, Worker installation,
and human session data it removes while preserving Work Root files and installation
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

