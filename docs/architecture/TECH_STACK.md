# Conclave AX Technology Stack

**Status:** Normative for Architecture v5

## Stack summary

| Layer | Technology |
| --- | --- |
| Conclave AX | Flutter + Dart, Web |
| Cloud | TypeScript + Cloudflare |
| Workspace runtime | Flutter + Dart desktop |
| Worker protocol | language-independent structured protocol |
| First-party Workers | Dart where practical |
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

v5 does not require a desktop Conclave AX binary.

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

The Workspace runtime is one Flutter/Dart desktop application. Its implementation currently lives under `apps/host` while the runtime migration proceeds.

Unlike v3, there is no separate Workspace UI and execution runtime product split.

The runtime process owns:
- Cloud WebSocket;
- journal/reconciliation;
- Worker manager;
- secure credential integration;
- child process supervision;
- repository/runtime capabilities;
- update lifecycle;
- minimal local UI.

Worker execution remains in separate OS child processes, retaining crash/cancellation/security isolation where it matters most.

## Workers

Workers are signed executable packages.

Preferred v4 local transport:
- structured JSON/JSON-RPC over stdin/stdout for ordinary per-assignment Worker processes.

A Worker may use:
- Dart;
- TypeScript/Node;
- Rust;
- Python;
- Go;
- another runtime,

when that runtime materially improves integration quality.

Protocol compatibility and signing matter more than implementation language.

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
- desired-state reconciliation for Workspace Worker installs;
- capability-based scheduling/security;
- bounded context assembly;
- durable audit events without full event sourcing.

## Workspace runtime architecture patterns

Prefer:
- supervisor pattern for Worker child processes;
- state machine for Worker install/update;
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
