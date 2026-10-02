# Conclave AX Architecture

**Current architecture:** v8 — one generic CLI Worker Engine with signed Tool Profiles.

**Release status:** The v8 release declaration remains gated by the acceptance evidence in the [implementation roadmap](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

## Product model

- **Conclave AX** is the human application for Projects, Workstreams, Discuss, Work, Workspace grants, Worker bindings, results, and audit.
- **Conclave Cloud** owns collaboration and scheduling state, the logical Worker catalog, Profile releases, and authorization. Provider credentials stay local.
- **Conclave Workspace** owns the local Work Root, Worker readiness, Profile verification and cache, Engine supervision, cancellation, and diagnostics.
- **Logical Workers** such as ChatGPT and Gemini are stable product identities. The Engine and Profile resolve each identity to a supported provider CLI.

## Work v1

Conclave owns the built-in Steps and Workflows defined by the [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md). Workstreams bind logical Workers to Direct and individual Steps. A Work Request snapshots its Workflow, bindings, models, instructions, attachment references, and prompt-profile versions.

The runtime implementation stays below the logical Worker boundary:

~~~text
Workstream binding -> logical Worker -> Profile resolution -> CLI Worker Engine -> provider CLI
~~~

## Runtime and protocol boundaries

~~~text
AX <-> Cloud                 Human Product Protocol
Cloud <-> Workspace          Workspace Runtime Protocol
Workspace <-> Engine          Local Worker Protocol 4.0
Engine <-> provider CLI       Profile-defined structured invocation
~~~

Each boundary has its own identity, authorization, transport, versioning, and wire schema. Provider credentials and raw provider session data do not enter Cloud APIs or the Workspace Runtime Protocol.

See [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md) and the [Tool Profile v1 specification](docs/specifications/TOOL_PROFILE_V1.md).

## Security and release trust

Cloud owns human identity, Project roles, Workspace ownership, Project-to-Workspace grants, Workstream authorization, step-up authentication, and Profile administration. Workspace verifies signed Profile payloads and supervises Engine and provider CLI processes. Signing keys remain in protected release infrastructure; provider credentials remain with the locally installed provider CLI.

See [Release Trust and Rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md), [Workspace release operations](docs/deployment/WORKSPACE_RELEASES.md), and [Workspace desktop lifecycle validation](docs/operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Current implementation status

The repository has converged on the v8 assignment path and clean v8 schema. The v8 release declaration remains withheld until the roadmap’s real-provider, release lifecycle, Work v1, and failure/security acceptance gates have retained evidence. See the [current implementation roadmap](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

## Current references

- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018: Generic CLI Worker Engine and Tool Profiles](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-Party Worker Catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace UX and data contract](docs/architecture/WORKSPACES_UX_CONTRACT.md)
