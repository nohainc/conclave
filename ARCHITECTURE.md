# Conclave AX Architecture

**Current architecture:** v7 — Workspace-owned Workers and managed Worker Package
execution. V7 is the sole current Worker ownership model and remains an active
implementation target until its production release gates pass.

## Product model

> **Projects and Workstreams choose how Workers are used. Workspaces report
> whether their local ChatGPT and Gemini Workers are ready and execute work.**

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> Worker executable -> provider CLI
```

- **Conclave AX** is the human-facing web application for Projects, Workstreams,
  Discuss, Work, Workspace grants, Worker role/model/fallback policy, results
  and audit.
- **Conclave Cloud** is the authoritative collaboration and scheduling control
  plane. It stores safe Workspace inventory and never receives provider
  credentials.
- **Conclave Workspace** is the persistent desktop runtime and machine security
  boundary. It owns local Workers, Conclave runtime credentials, permissions,
  Work Root, Worker Package admission, process execution and local diagnostics.
- **Worker Type** identifies a managed integration. The frozen first-party v1
  catalog is ChatGPT via its Codex-backed Worker Package and Gemini via its
  Antigravity-backed Worker Package; broader integrations remain
  implementation/migration scope. Models are not Worker Types.

Conclave Workspace never discovers, versions, authenticates with, or executes provider tools directly. Worker Runtime v2 launches an admitted standalone Worker executable through Local Worker Protocol 3.0; that Worker owns all provider-specific tool interaction. First-party ChatGPT and Gemini Workers are independently versioned Dart console executables.

Each configured Worker belongs to exactly one Workspace. AX Workstream policy
chooses the Workspace/Worker for each task role, model, fallback behavior, and
Cloud concurrency. Cloud scheduling state and Project grants bound eligibility;
the Workspace's local Ready state, permissions, and concurrency remain the
execution safety boundary. See [ADR-016](docs/decisions/ADR-016-ax-owned-worker-usage.md).

## Workstream and execution protocol

Conclave has three distinct protocol boundaries: the Human Product Protocol
between AX and Cloud, the Workspace Runtime Protocol between the Workspace
runtime and Cloud's Workspace Gateway, and the Local Worker Protocol between
the Workspace process supervisor and a Worker Package process. They share
canonical domain IDs/types but never share or forward wire envelopes. AX does
not speak the Workspace Runtime Protocol, and Worker Packages never connect directly
to Cloud. See the [Protocol Boundaries contract](docs/architecture/PROTOCOL_BOUNDARIES.md)
for endpoint, credential, transport, and schema ownership.

Each Workstream has an ID-derived local directory under the Workspace Work
Root. Stateful execution is fenced and restricted to the Workstream Primary
Workspace. Stateless work may use another eligible Workspace only when grants
and policy allow it.

The current Node-backed V7 Local Worker Protocol supports versions 2.1 through 2.6. ADR-017 accepts Worker Runtime v2 / Local Worker Protocol 3.0 as the target for standalone native Dart Worker executables, including explicit Worker version/state compatibility in addition to passive/live probes, assignment deadlines, Conclave session policies, and Worker-reported provider tool diagnostics. It consists of
`initialize.request/result`, `probe.request/result`, `execute.request`,
`progress`, `result`, and `error`. Each exchange carries a request ID. Probe
results contain package-reported readiness, the requested mode, a safe
provider-tool name, resolved executable path and version, structured checks,
stable issue codes, and bounded local diagnostics;
the wire schema has no provider token or account-secret fields.

## Implementation status

V7 ownership, Cloud scheduling, real V7 assignment execution, and V6 Worker
compatibility retirement are implemented. Production Worker coverage,
adversarial acceptance, and native macOS app update recovery remain open; do
not describe V7 as the implemented baseline until all release gates pass.

## Current references

- [Architecture v7](docs/architecture/ARCHITECTURE_V7.md)
- [ADR-012: Workspace-owned Workers](docs/decisions/ADR-012-workspace-owned-local-workers.md)
- [ADR-015: First-party Worker v1 contract](docs/decisions/ADR-015-first-party-worker-v1-contract.md)
- [ADR-016: AX-owned Worker usage](docs/decisions/ADR-016-ax-owned-worker-usage.md)
- [ADR-017: Standalone Dart Worker executables](docs/decisions/ADR-017-standalone-dart-worker-executables.md)
- [Worker Runtime v2 architecture](docs/architecture/WORKER_RUNTIME_V2.md)
- [Worker Runtime v2 implementation plan](docs/roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md)
- [First-party Worker catalog contract v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Applications and product boundaries](docs/architecture/APPLICATIONS.md)
- [AX Workspaces UX and data contract](docs/architecture/WORKSPACES_UX_CONTRACT.md)
- [Technology stack](docs/architecture/TECH_STACK.md)
- [V7 implementation audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)
- [V7 completion plan and release gates](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)
- [V7 failure and security acceptance](docs/architecture/V7_FAILURE_RECOVERY_ACCEPTANCE.md)
- [Deployment guidance](docs/deployment/CLOUDFLARE.md)
- [Workspace and Worker release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and key rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)

## Historical documents

Architecture v4–v6 and ADR-009/ADR-010 preserve the decisions made during the
earlier migration. ADR-012 defines the current general execution architecture;
ADR-015 defines the current first-party v1 catalog, cardinality, and provider
authentication boundary.
