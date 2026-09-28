# Conclave AX Architecture

**Current architecture:** v7 — Workspace-owned Workers and managed adapter
execution. V7 is the sole current Worker ownership model and remains an active
implementation target until its production release gates pass.

## Product model

> **Projects and Workstreams choose how Workers are used. Workspaces report
> whether their local ChatGPT and Gemini Workers are ready and execute work.**

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> Worker adapter process
```

- **Conclave AX** is the human-facing web application for Projects, Workstreams,
  Discuss, Work, Workspace grants, Worker role/model/fallback policy, results
  and audit.
- **Conclave Cloud** is the authoritative collaboration and scheduling control
  plane. It stores safe Workspace inventory and never receives provider
  credentials.
- **Conclave Workspace** is the persistent desktop runtime and machine security
  boundary. It owns local Workers, credentials, permissions, prerequisites,
  Work Root, adapter admission, process execution and local diagnostics.
- **Worker Type** identifies a managed integration. The frozen first-party v1
  catalog is ChatGPT via Codex CLI and Gemini via Antigravity CLI; broader
  adapters remain implementation/migration scope. Models are not Worker Types.

Each configured Worker belongs to exactly one Workspace. AX Workstream policy
chooses the Workspace/Worker for each task role, model, fallback behavior, and
Cloud concurrency. Cloud scheduling state and Project grants bound eligibility;
the Workspace's local Ready state, permissions, and concurrency remain the
execution safety boundary. See [ADR-016](docs/decisions/ADR-016-ax-owned-worker-usage.md).

## Workstream and execution protocol

Each Workstream has an ID-derived local directory under the Workspace Work
Root. Stateful execution is fenced and restricted to the Workstream Primary
Workspace. Stateless work may use another eligible Workspace only when grants
and policy allow it.

The initial V7 adapter protocol consists of `initialize`, `validate`,
`execute`, `progress`, `result`, `error`, `health`, and `version` messages.
Interactive request/response input is a future versioned extension unless a
production-supported adapter requires it.

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
- [First-party Worker catalog contract v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Applications and product boundaries](docs/architecture/APPLICATIONS.md)
- [AX Workspaces UX and data contract](docs/architecture/WORKSPACES_UX_CONTRACT.md)
- [Technology stack](docs/architecture/TECH_STACK.md)
- [V7 implementation audit](docs/architecture/V7_IMPLEMENTATION_AUDIT.md)
- [V7 completion plan and release gates](docs/roadmaps/ARCHITECTURE_V7_COMPLETION.md)
- [V7 failure and security acceptance](docs/architecture/V7_FAILURE_RECOVERY_ACCEPTANCE.md)
- [Deployment guidance](docs/deployment/CLOUDFLARE.md)
- [Workspace and adapter release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and key rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)

## Historical documents

Architecture v4–v6 and ADR-009/ADR-010 preserve the decisions made during the
earlier migration. ADR-012 defines the current general execution architecture;
ADR-015 defines the current first-party v1 catalog, cardinality, and provider
authentication boundary.
