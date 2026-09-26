# Conclave AX Technology Stack

**Status:** Current v7 architecture; production readiness gates remain open

## Stack summary

| Layer | Technology |
| --- | --- |
| Conclave AX | Flutter + Dart, Web |
| Cloud | TypeScript + Cloudflare |
| Conclave Workspace | Flutter + Dart desktop/background runtime |
| Worker adapter protocol | language-independent structured protocol |
| First-party adapters | Dart where practical |
| Cloud database | Cloudflare D1 |
| Artifacts/packages | Cloudflare R2 |
| Durable orchestration | Cloudflare Workflows |
| Workspace connectivity | Durable Objects + WebSocket |
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

Adapter execution remains in separate per-assignment OS child processes, retaining crash/cancellation/security isolation while keeping the Cloud connection/runtime stable.

## Worker adapters

Worker Types are implemented by signed adapter packages managed by Conclave Workspace.

Preferred local transport:
- structured JSON/JSON-RPC over stdin/stdout for ordinary per-assignment adapter processes.

An adapter may use:
- Dart;
- TypeScript/Node;
- Rust;
- Python;
- Go;
- another runtime,

when that runtime materially improves integration quality.

Protocol compatibility, package signing, prerequisite detection and process isolation matter more than implementation language.

A configured Worker is local configuration/state that references one adapter type; it is not itself a separately installed binary.

## Cross-language contracts

Keep one canonical protocol schema source.

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

The adapter protocol version 1.0 defines `initialize`, `validate`, `execute`,
`progress`, `result`, `error`, `health`, and `version`. Interactive
request/response input is intentionally deferred to a future versioned
extension unless required by a production-supported adapter.

See the [Architecture v7 Completion Plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md),
[release operations](../deployment/WORKSPACE_RELEASES.md), and
[release trust/key rotation](../security/RELEASE_TRUST_AND_ROTATION.md).
