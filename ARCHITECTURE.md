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

## v8 architecture contract

Architecture v8 has one execution path: AX → Cloud → Workspace → CLI Worker Engine → signed Tool Profile → provider CLI. The explicit exclusions in the
[v8 architecture contract](docs/architecture/ARCHITECTURE_V8.md#architecture-contract)
are normative and checked by `scripts/verify-v8-architecture.mjs`.

## Product model

- **Conclave AX** is the human application for Projects, Workstreams, team Chat, AI execution through Work Requests, Workspace grants, Worker bindings, results, and audit.
- **Conclave Cloud** owns collaboration and scheduling state, the logical Worker catalog, Profile releases, and authorization. Provider credentials stay local.
- **Conclave Workspace** owns the local Work Root, Worker readiness, Profile verification and cache, Engine supervision, cancellation, and diagnostics.
- **Logical Workers** such as ChatGPT and Gemini are stable product identities. The Engine and Profile resolve each identity to a supported provider CLI.

## Work v1

Conclave owns the built-in Steps and Workflows defined by the [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md). Workstreams bind logical Workers to Work (`direct:v2`) and individual Steps. Historical `direct:v1` snapshots retain the name Direct. A Work Request snapshots its Workflow, bindings, models, instructions, attachment references, and prompt-profile versions.

| Workflow | Filesystem authority | Provider session | Mutation coordination |
| --- | --- | --- | --- |
| Chat (`chat:v1`) | Read-only conversation | Durable, scoped to Workstream Chat | Stateless request; no mutation lease |
| Work (`direct:v2`) | Writable within authorized Workstream policy | Durable, scoped to Workstream Work | Stateful request; mutation lease and fencing |

Work is the user-facing current version of the stable internal Workflow ID
`direct`; persisted IDs and historical snapshots are never renamed for display.
Chat and Work have separate provider sessions even when their Worker/model match.
Research and Plan retain read-only analysis semantics. Implement remains writable;
Test and Verify retain their existing read-only validation/review semantics and
coordination. Their sessions remain request/Step-scoped. Tool Profiles implement
permission policies without provider branches in Cloud, Workspace or AX.
See the [operator workflow guide](docs/operations/WORKSTREAM_EXECUTION.md) and
[regression coverage](docs/acceptance/CHAT_WORKFLOW.md).

The runtime implementation stays below the logical Worker boundary:

~~~text
Workstream binding -> logical Worker -> Profile resolution -> CLI Worker Engine -> provider CLI
~~~

## Conversation Workflow ownership

Current manual Chat and Work requests belong to persistent, Workflow-owned
Conversations within their Workstream. Conversation revisions count accepted
requests; context revisions track accepted-request context boundaries.
User messages link to stable logical WorkflowRuns; each run owns multiple Worker
turns grouped by stable WorkflowStepRuns, plus existing scheduler Run attempts,
including retries. Run timestamps record first-start and terminal evidence. Work Request remains
the single lifecycle/configuration owner. Run/step orchestration remains internal;
ordinary Chat and Work retain conversation presentation and request-based controls.
A future step-list presentation adapter requires explicit enablement and a matching
versioned multi-step workflow; backend record counts alone never enable it.
Per-assignment turns preserve immutable
execution attribution, and lifecycle evidence; retries retain separate records.
The CLI Worker Engine reconstructs unavailable native sessions at the Worker-step
boundary using frozen canonical context, within the same assignment and workflow
run. Rejected handles remain invalidated locally until replacement succeeds;
signed Profile error mappings authorize one bounded reconstruction attempt.
Dispatch and StepRun evidence retain the frozen request context boundary. Local
session synchronization advances only on successful consumption and cannot move
backwards; revision and history-watermark evidence is recorded in local diagnostics.
Concurrent steps retain independent context evidence, including a frozen snapshot
fingerprint. Native session execution is exclusive across local Engine processes;
different Workers and stateless steps remain independent.
Versioned product Workflow definitions pin existing execution graphs, with
Work (`work:v1`) mapped to `direct:v2`. Native provider continuity remains local to Workspace/Engine. Conclave owns an append-only canonical history of messages,
responses, workflow/execution events, artifact events, and context events; provider
sessions remain execution state. The provider-independent Context Engine assembles canonical bootstrap, delta and
stateless context. Persistent conversation facts are distinct from receiving-step
workflow execution context, including scoped environment, artifacts and completed
prerequisite results. Signed Profiles also project versioned, generic Worker execution
options for model selection, session model switching, and model-specific effort;
provider argument mapping stays local to the Engine. See [Conversation Continuity v1](docs/specifications/CONVERSATION_CONTINUITY_V1.md).

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
- [ADR-019: Conclave Profile Lab Architecture Contract](docs/decisions/ADR-019-conclave-profile-lab.md)
- [Conversation Continuity Phase 0 audit](docs/architecture/CONVERSATION_CONTINUITY_PHASE_0_AUDIT.md)
- [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-Party Worker Catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Tool Profile Lifecycle](docs/specifications/TOOL_PROFILE_LIFECYCLE.md)
- [Tool Profile Evidence Contract](docs/specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace UX and data contract](docs/architecture/WORKSPACES_UX_CONTRACT.md)

## AX client server-state foundation

The isolated in-memory [AX server-state layer](docs/architecture/AX_SERVER_STATE.md)
provides typed query caching, scoped listeners, race protection, and optimistic
mutations over existing HTTP loaders. Project/sidebar navigation now consumes
independent cached Project details and Workstream collections, retaining
expanded Projects across navigation. Navigation synchronously changes route
state and ensures those resources in the background; `loadBootstrapState` remains
a bootstrap/recovery API. Work history uses a shared infinite query with a
bounded recent page, on-demand older pages, and targeted realtime reconciliation.
Healthy sockets disable Work polling; a fifteen-second fallback runs during
outages and stops after scoped recovery. The shell has no five-second snapshot
polling: Run/execution signals reconcile identified Work Requests and never
reload bootstrap, Projects, Workspaces, or session data.
An optional, user-scoped IndexedDB read cache restores allowlisted server data
after Cloud authentication, renders it as stale, and revalidates in the background.
Logout clears memory and that user's persisted data; credentials and pending
mutations are never persisted. In memory, AX keeps 20 recent Workstream histories
and up to 200 rows per inactive collection, protecting visible histories and
pending operations. Eviction releases cache data only; Projects and the Workflow
catalog remain cached for the authenticated session. Collaboration state lives
in shared queries; the shell exposes only a legacy execution projection. Browser foreground return and network restoration
revalidate active stale queries in the background while cached content stays
visible; temporary failures show a narrow connectivity/staleness notice. Stable
Project and Workflow reads use optional [content revisions](docs/specifications/AX_CONDITIONAL_READS.md)
to avoid retransmitting unchanged representations after authorization.

AX Discussion history uses shared, paginated in-memory state with per-message
optimistic writes; see [server-state ownership](docs/architecture/AX_SERVER_STATE.md)
and the [v1 paging contract](docs/specifications/DISCUSSION_PAGING.md).
