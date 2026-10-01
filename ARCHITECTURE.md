# Conclave AX Architecture

**Current architecture:** v7 — Workspace-owned Workers and managed Worker
executable lifecycle. Worker Runtime v2 / ADR-017 is the normative first-party
runtime: signed, independently versioned Dart console executables using Local
Worker Protocol 3.0. Full Workspace assignment-path convergence and production
acceptance remain open; current source still routes assignments through the
legacy V7 Node adapter store/executor.

## Product model

> **Projects and Workstreams choose how Workers are used. Workspaces report
> whether their local ChatGPT and Gemini Workers are ready and execute work.**

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace -> Worker executable -> provider CLI
```

- **Conclave AX** is the human-facing web application for Projects, Workstreams,
  Discuss, Work, Workspace grants, canonical Workflow/Step Worker bindings, results
  and audit.
- **Conclave Cloud** is the authoritative collaboration and scheduling control
  plane. It stores safe Workspace inventory and never receives provider
  credentials.
- **Conclave Workspace** is the persistent desktop runtime and machine security
  boundary. It owns local Workers, Conclave runtime credentials, permissions,
  Work Root, Worker release admission, process execution and local diagnostics.
- **Worker Type** identifies a managed integration. The frozen first-party v1
  catalog is ChatGPT via its Codex-backed Worker executable and Gemini via its
  agy-backed Worker executable; broader integrations remain
  implementation/migration scope. Models are not Worker Types.

Conclave Workspace never discovers, versions, authenticates with, or executes provider tools directly. Worker Runtime v2 launches an admitted standalone Worker executable through Local Worker Protocol 3.0; that Worker owns all provider-specific tool interaction. First-party ChatGPT and Gemini Workers are independently versioned Dart console executables.

Each configured Worker belongs to exactly one Workspace. Workstream config
binds a Worker to Direct and each canonical Step, with optional model and
fallback settings. Cloud scheduling state and Project grants bound eligibility;
the Workspace's local Ready state, permissions, and concurrency remain the
execution safety boundary. See [ADR-016](docs/decisions/ADR-016-ax-owned-worker-usage.md).

## Workstream and execution protocol

Work execution follows one product-owned path:

~~~text
Conclave defines canonical Steps
        ↓
Conclave defines the valid built-in Workflows
        ↓
Workstream configuration binds Workers to Direct and canonical Steps
        ↓
The user selects a Workflow and submits a request
        ↓
Cloud snapshots the request and composes each Step prompt
        ↓
Workspace launches the selected Worker executable
        ↓
Workers execute through their provider tools
~~~

Work v1 has a closed `StepKind` set and five versioned built-in Workflow
definitions in the shared core catalog. Users select among those definitions;
they do not create Workflows, reorder Steps, define dependencies, add branches,
or edit Conclave's internal prompts. Workstream configuration stores the
default Workflow, fixed Direct/Step Worker bindings, and optional model,
fallback, and additional instructions.

Each submitted Work Request stores an immutable snapshot of its original
request and attachment references, Workflow ID/version/definition, resolved
Worker bindings and model selections, Project/Workstream/Step instructions,
and prompt-profile versions. Later configuration changes cannot alter a
running or historical request. Cloud renders the versioned internal Step
Prompt Profiles from structured inputs and the fixed handoff rules. These
profiles are product implementation data, not a user-facing template or macro
language. See the [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md)
for the exact configuration, snapshot, and handoff contracts.

Conclave has three distinct protocol boundaries: the Human Product Protocol
between AX and Cloud, the Workspace Runtime Protocol between the Workspace
runtime and Cloud's Workspace Gateway, and the Local Worker Protocol between
the Workspace process supervisor and a Worker process. They share
canonical domain IDs/types but never share or forward wire envelopes. AX does
not speak the Workspace Runtime Protocol, and Workers never connect directly to
Cloud. See the [Protocol Boundaries contract](docs/architecture/PROTOCOL_BOUNDARIES.md)
for endpoint, credential, transport, and schema ownership.

Each Workstream has an ID-derived local directory under the Workspace Work
Root. Its Work configuration selects a default built-in Workflow and binds
each canonical Step to a Worker, with optional model, fallback Worker, and
additional instructions. Stateful execution is fenced and restricted to the
Workstream Primary Workspace. Stateless work may use another eligible
Workspace only when grants and policy allow it.

The normative first-party Local Worker Protocol is version 3.0. The Node-backed
V7 Protocol 2.1–2.6 describes the historical migration implementation only.
Protocol 3.0 uses standalone native Dart Worker executables and validates exact
Worker identity/version, protocol negotiation, state compatibility, and
capabilities. Probes explicitly select passive/live modes; execute carries
assignment deadlines and Conclave session policy. Provider tool diagnostics
are Worker-reported and provider secrets never enter the protocol. The required
frames are
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
- [Work v1 contract: StepKinds and built-in Workflows](docs/specifications/WORK_V1_CONTRACT.md)
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
