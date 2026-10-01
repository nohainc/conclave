# Conclave AX Technology Stack

**Status:** Architecture v8 is the active target. Architecture v7 is the
historical baseline; Worker Runtime v2 is its process-boundary predecessor.

## Stack summary

| Layer | Technology |
| --- | --- |
| Conclave AX | Flutter + Dart, Web |
| Cloud | TypeScript + Cloudflare |
| Conclave Workspace | Flutter + Dart desktop/background runtime |
| Local Worker Protocol | Protocol 4.0, versioned NDJSON between Workspace and Engine |
| First-party local execution | Generic Dart AOT CLI Worker Engine plus signed Tool Profiles |
| Cloud database | Cloudflare D1 |
| Artifacts/packages | Cloudflare R2 |
| Durable orchestration | Cloudflare Workflows |
| Workspace connectivity | Durable Objects + WebSocket |
| AX-to-Cloud product boundary | HTTPS APIs + browser realtime, human session |
| Workspace-to-Cloud runtime boundary | Workspace Runtime Protocol over WSS, HTTPS long-poll fallback |
| Workspace-to-Engine boundary | Local Worker Protocol 4.0 over NDJSON stdin/stdout |
| Web hosting | Cloudflare static assets / Worker deployment |
| TypeScript tests | Vitest |
| Dart/Flutter tests | dart test / flutter_test |
| CI/CD | GitHub Actions |
| Cloud deploy | Wrangler |

## Conclave AX

Flutter remains appropriate because:
- one responsive web UI;
- strong reuse for a future mobile app;
- consistent design system;
- good adaptive layout support.

Conclave AX remains a web application. The native desktop product is Conclave Workspace.

## Cloud

TypeScript remains the preferred Cloud language because Cloudflare's runtime/tooling is JavaScript/TypeScript-first and the existing orchestration/persistence/security code is already TypeScript.

Use:
- Workers for HTTP/API;
- Workflows for durable Run orchestration;
- D1 for relational control-plane state;
- R2 for artifacts and signed Engine/Profile release packages;
- Durable Objects for live Workspace runtime WebSockets and transient coordination.

Do not add PostgreSQL/Redis/Kafka/Kubernetes without measured need.

## Workspace runtime

Conclave Workspace is one Flutter/Dart desktop application/runtime. Its implementation currently lives under `apps/host`.

There is no separately installed Worker application.

The persistent runtime process owns:
- Cloud WebSocket;
- Workspace enrollment/reconciliation;
- local configured Worker registry;
- secure credential integration;
- logical Worker registry and Tool Profile resolver/cache;
- Work Root/Workstream directory lifecycle;
- child process supervision;
- local permissions and diagnostics;
- update lifecycle;
- minimal local UI/tray behavior.

Worker execution uses a separate CLI Worker Engine process per assignment/probe
by default, retaining crash/cancellation/security isolation while keeping the
Cloud connection/runtime stable. The Engine starts the locally installed
Provider CLI. Users do not install a provider-specific Conclave Worker
executable, Node.js, or the Dart SDK.
Workspace owns each Worker's full descendant tree. Assignment cancellation,
timeout, output overflow, Worker removal, and runtime shutdown first give the
Worker a brief graceful-stop window to clean up its provider CLI. Workspace
then force-terminates the full tree and waits for executor cleanup before
shutdown completes. Provider CLIs remain in the Workspace-owned process group.
POSIX process groups are used for force termination, with recursive process
discovery as fallback; Windows uses process-tree termination.

## Architecture v8 local execution target

Preferred local runtime:

~~~text
Conclave Workspace (Flutter/Dart)
-> Local Worker Protocol 4.0
-> generic Dart CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

The Engine is a separate generic console executable, not a Flutter plugin and
not provider-specific. Tool Profile Releases are immutable signed
configurations distributed by Cloud and cached/verified by Workspace.
Provider-specific arguments, event mappings, sessions, and compatibility
belong in Profiles when representable by Tool Profile v1.

**Migration boundary:** Worker Runtime v2 provider-specific Dart binaries,
release records, and their test suites are retained only as migration
references until the v8 real-provider, update/rollback, and Work v1 acceptance
gates pass. They are not the active architecture target and must not be extended
for new CLI integrations. Remove them in the v8 cleanup phase after acceptance.

## Cross-language contracts

Keep one canonical schema source per protocol boundary. The Human Product,
Workspace Runtime, and Local Worker Protocol contracts have separate endpoint owners,
authentication, versions, and wire schemas. Their shared domain IDs/types do
not justify sharing an envelope or importing another boundary's transport.

Generate/validate TypeScript and Dart bindings.

Do not hand-maintain semantically duplicate protocol models.

## UI architecture

Use feature-oriented Flutter organization with:
- view;
- controller/view-model/store;
- repository/API boundary;
- immutable read models.

Avoid a single giant application snapshot over time.

Use adaptive layouts:
- wide: persistent project/chat navigation;
- medium: collapsible navigation;
- narrow: single-column navigation/drawers/sheets.

Support keyboard, mouse, touch and accessibility semantics.

## Cloud architecture patterns

Prefer:
- hexagonal ports at domain boundaries;
- functional core / imperative shell;
- explicit state machines;
- immutable Assignment snapshots;
- idempotent commands;
- desired-state reconciliation for approved Worker releases and remote scheduling state;
- capability-based scheduling/security;
- bounded context assembly;
- durable audit events without full event sourcing.

## Workspace runtime architecture patterns

Prefer:
- supervisor pattern for Worker/provider-tool child processes;
- state machine for Worker install/update;
- local-first configured Worker registry with safe Cloud inventory sync;
- platform-specific implementations only for genuinely OS-specific behavior;
- secure-store abstraction;
- bounded logs/output;
- explicit cancellation and process-tree termination;
- idempotent desired-state reconciliation.

## Storage rule

D1 stores metadata/state.

R2 stores large immutable artifacts and packages.

Local Workspace secure store stores personal secrets by default.

Do not persist plaintext credentials in D1, assignment payloads, logs, or artifacts.


## Historical Architecture v7 status

At the v7 baseline, the product model used Workspace-owned local Workers, safe Cloud
inventory, Cloud scheduling controls, Project/Workstream authorization, and
execution by the owning Workspace. The scheduler no longer needs V6 binding
records for V7 assignments. Public-key trust and first-party release workflows
are implemented. V7 is not yet the declared implemented baseline: production
Worker live acceptance, full failure/security acceptance, and native macOS
`.app` update/recovery remain release gates.

**Historical migration implementation:** the Node-backed Local Worker Protocol
supports versions 2.1 through 2.6 and defines correlated
`initialize.request/result`, `probe.request/result`, `execute.request`,
`progress`, `result`, and `error` frames. Versions 2.3 and 2.4 probe results expose the
requested passive/live mode, readiness, safe tool version, structured checks,
stable issue codes, and bounded local diagnostics. Protocol 2.4 execute
requests carry the remaining assignment timeout so packages can derive CLI
deadlines and reserve cleanup grace. Provider tokens and account secrets are
not protocol fields. This describes the legacy source route, not the current
first-party contract. Local Worker Protocol 4.0 is normative for first-party
CLI Worker Engine work; Workspace must not probe provider CLIs directly.

See the [Architecture v7 Completion Plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md),
[release operations](../deployment/WORKSPACE_RELEASES.md), and
[release trust/key rotation](../security/RELEASE_TRUST_AND_ROTATION.md).


## Architecture v8 implementation status

Architecture v8 is the accepted implementation target. Existing code includes
the v7/v2 Workspace process boundary and provider-specific Worker artifacts as
migration baselines; the generic Engine + signed Profile assignment path is
not yet accepted. Follow the ordered
[Architecture v8 implementation plan](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md)
and do not report v8 complete until its real-provider, profile
activation/update/rollback, Work v1, and cleanup gates pass.
