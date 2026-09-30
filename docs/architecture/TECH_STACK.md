# Conclave AX Technology Stack

**Status:** Current v7 architecture; production readiness gates remain open

## Stack summary

| Layer | Technology |
| --- | --- |
| Conclave AX | Flutter + Dart, Web |
| Cloud | TypeScript + Cloudflare |
| Conclave Workspace | Flutter + Dart desktop/background runtime |
| Local Worker Protocol | versioned provider-neutral NDJSON protocol |
| First-party Workers | standalone Dart AOT console executables |
| Cloud database | Cloudflare D1 |
| Artifacts/packages | Cloudflare R2 |
| Durable orchestration | Cloudflare Workflows |
| Workspace connectivity | Durable Objects + WebSocket |
| AX-to-Cloud product boundary | HTTPS APIs + browser realtime, human session |
| Workspace-to-Cloud runtime boundary | Workspace Runtime Protocol over WSS, HTTPS long-poll fallback |
| Workspace-to-Worker boundary | Local Worker Protocol over NDJSON stdin/stdout |
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
- R2 for artifacts and signed Worker/release packages;
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
- Worker Type adapter manager;
- Work Root/Workstream directory lifecycle;
- child process supervision;
- local permissions and diagnostics;
- update lifecycle;
- minimal local UI/tray behavior.

Worker execution remains in separate per-assignment OS child processes, retaining crash/cancellation/security isolation while keeping the Cloud connection/runtime stable. Under Worker Runtime v2, first-party ChatGPT and Gemini integrations are standalone independently versioned Dart console executables; the user does not install Node.js or the Dart SDK.
Workspace owns each adapter's full descendant tree. Assignment cancellation,
timeout, output overflow, Worker removal, and runtime shutdown first give the
package a brief graceful-stop window to clean up its provider CLI. Workspace
then force-terminates the full tree and waits for executor cleanup before
shutdown completes. Provider CLIs remain in the Workspace-owned process group.
POSIX process groups are used for force termination, with recursive process
discovery as fallback; Windows uses process-tree termination.

## Worker Runtime v2

First-party Worker Types are implemented as signed standalone Dart native
executables managed by Conclave Workspace.

Preferred first-party structure:

~~~text
Conclave Workspace (Flutter/Dart)
-> Local Worker Protocol 3.0
-> Dart Worker executable
-> provider CLI/tool
~~~

Workspace installs, verifies, activates, supervises, updates and rolls back
Worker executables. A Worker owns provider CLI discovery, version/auth checks,
environment interpretation, execution, output parsing, provider session IDs
and provider-specific diagnostics.

The first-party Workers are console applications, not Flutter plugins. They
compile with `dart compile exe` into self-contained platform/architecture
artifacts. No Node.js or Dart SDK is required on the user machine.

Third-party Workers may use another implementation language only when they
still satisfy the same signed Worker release, process isolation, protocol,
permission and update contracts.

Worker versions are independent from both Workspace and provider CLI versions.
Workspace may keep multiple verified Worker versions installed and atomically
switch/rollback the active version.

See [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md) and
[Worker Runtime v2](WORKER_RUNTIME_V2.md).

## Cross-language contracts

Keep one canonical schema source per protocol boundary. The Human Product,
Workspace Runtime, and Local Adapter contracts have separate endpoint owners,
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
- desired-state reconciliation for approved adapter releases and remote scheduling state;
- capability-based scheduling/security;
- bounded context assembly;
- durable audit events without full event sourcing.

## Workspace runtime architecture patterns

Prefer:
- supervisor pattern for adapter/tool child processes;
- state machine for adapter install/update;
- local-first configured Worker registry with safe Cloud inventory sync;
- platform adapters only for genuinely OS-specific behavior;
- secure-store abstraction;
- bounded logs/output;
- explicit cancellation and process-tree termination;
- idempotent desired-state reconciliation.

## Storage rule

D1 stores metadata/state.

R2 stores large immutable artifacts and packages.

Local Workspace secure store stores personal secrets by default.

Do not persist plaintext credentials in D1, assignment payloads, logs, or artifacts.


## V7 implementation status

The current product model is V7: Workspace-owned local Workers, safe Cloud
inventory, Cloud scheduling controls, Project/Workstream authorization, and
execution by the owning Workspace. The scheduler no longer needs V6 binding
records for V7 assignments. Public-key trust and first-party release workflows
are implemented. V7 is not yet the declared implemented baseline: production
Worker live acceptance, full failure/security acceptance, and native macOS
`.app` update/recovery remain release gates.

The Local Worker Protocol supports versions 2.1 through 2.6 and defines correlated
`initialize.request/result`, `probe.request/result`, `execute.request`,
`progress`, `result`, and `error` frames. Versions 2.3 and 2.4 probe results expose the
requested passive/live mode, readiness, safe tool version, structured checks,
stable issue codes, and bounded local diagnostics. Protocol 2.4 execute
requests carry the remaining assignment timeout so packages can derive CLI
deadlines and reserve cleanup grace. Provider tokens and account secrets are
not protocol fields.

See the [Architecture v7 Completion Plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md),
[release operations](../deployment/WORKSPACE_RELEASES.md), and
[release trust/key rotation](../security/RELEASE_TRUST_AND_ROTATION.md).


## Worker Runtime v2 implementation status

Worker Runtime v2 is an accepted target, not yet the implemented baseline. The current main branch still contains the Node-backed first-party Worker implementation until the ChatGPT and Gemini Dart Workers, native release/update/rollback transaction, real provider acceptance, and cleanup gates in the Worker Runtime v2 roadmap pass.
