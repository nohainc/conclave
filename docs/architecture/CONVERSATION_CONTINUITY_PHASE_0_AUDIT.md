# Conversation Continuity — Phase 0 execution audit

**Date:** 2026-10-07. **Scope:** current repository implementation after commit
`eeddc55a`; audit only, before any Conversation subsystem migration.

This is an implementation inventory, not a new architecture contract. Architecture
v8 and Work v1 remain authoritative. The proposed Conversation, canonical history,
Context State, Context Revision, and Turn entities do not exist as dedicated
persisted domain entities today.

## Terminology and boundaries

AX's **Chat tab** is human team Discussion, stored in `discussion_messages`.
The **Chat workflow** (`chat:v1`) is AI execution selected inside **Work**. These
are distinct paths. Work (`direct:v2`) is another AI workflow; historical
`direct:v1` retains its original snapshot. The stable `direct` identifier must
not be confused with the `implement` Step it executes.

Current AI hierarchy is Space → Thread → Work Request → Workflow Tasks /
Run → Worker Assignments. The product has no independently addressable
Conversation between Thread and Work Request. A Workflow determines Steps,
permissions and execution coordination; bindings select Workers and optionally
models/efforts. Logical Worker identity is distinct from its signed Tool Profile
and local provider CLI implementation.

Sources: [architecture](../../ARCHITECTURE.md), [v8 contract](ARCHITECTURE_V8.md),
[ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md),
[Work v1](../specifications/WORK_V1_CONTRACT.md).

## End-to-end trace

| Stage | Chat workflow | Work workflow | Implementation |
| --- | --- | --- | --- |
| Composer | Selects `chat`; reads `chat` binding | Selects `direct`; reads `direct` binding | [Work controls](../../apps/app/lib/src/features/spaces/spaces_pages/work_components.dart) |
| Settings | Worker, optional model, optional `reasoningEffort` | Same, independent binding | [page handlers](../../apps/app/lib/src/features/spaces/spaces_pages/thread_page.dart), [settings save](../../apps/app/lib/src/features/spaces/spaces_pages/thread_actions.dart) |
| Submit | Sends Workflow ID, original request, attachments and idempotency key | Same | [AX API](../../apps/app/lib/src/ax/ax_data/thread_api.dart) |
| Cloud creation | Resolves canonical `chat:v1`, validates eligibility, snapshots binding | Resolves canonical `direct:v2`, snapshots `direct` binding | [creation](../../apps/cloud/src/routes/work-creation.ts), [core definitions](../../packages/core/src/thread.ts) |
| Orchestration | Stateless request coordination; read-only; durable provider session | Stateful Thread coordination; writable policy; durable provider session | [Workflow runner](../../apps/cloud/src/workflow.ts) |
| Scheduling | Resolves logical Worker to authorized Workspace inventory and eligible Profile | Same, with mutation lease/fencing | [scheduler](../../apps/cloud/src/scheduler.ts), [dispatcher](../../apps/cloud/src/assignment-dispatcher.ts) |
| Workspace | Validates assignment and local policy; supplies Thread directory and Worker state directory | Same, enforcing authorized filesystem policy | [assignment admission](../../apps/workspace/lib/cloud_connection/assignment_handlers.dart), [runtime](../../apps/workspace/lib/workspace_runtime.dart) |
| Engine | Reads local session mapping, interprets signed Profile, starts CLI with structured arguments | Same | [supervisor](../../packages/conclave_cli_worker_runtime/lib/src/cli_worker_engine_supervisor.dart), [Engine](../../engines/cli_worker/lib/src/cli_worker_engine.dart) |
| Result | CLI output becomes WorkerResult, assignment output, StepResult and Work history | Same | [runner](../../apps/cloud/src/workflow.ts), [history projection](../../apps/cloud/src/routes/work-lifecycle.ts) |

Workspace Runtime transport/authentication session IDs are separate from provider
conversation/thread IDs. Reconnecting the Workspace socket does not reconstruct a
provider conversation from Cloud history.

## Storage and ownership inventory

| Information | Current location and ownership |
| --- | --- |
| Workflow defaults/type | `thread_work_configs.config_json.defaultWorkflowId`; executable built-ins/versioned definitions in Core. Each request stores `work_requests.workflow_id`, `workflow_version`, `workflow_snapshot_json`. |
| Selected Worker | Mutable Thread `config_json.bindings[bindingId].workerId`; immutable resolved binding in `work_requests.snapshot_json`; concrete scheduling target in `worker_assignments` (Worker type, Workspace Worker ID, runtime identity, Workspace). |
| Model | Optional binding `model`, request binding snapshot, assignment `model`, dispatched assignment evidence, completed StepResult `model`. |
| Effort | Optional binding `reasoningEffort`, request snapshot, assignment dispatch/evidence JSON and completed StepResult. There is no dedicated effort column in `worker_assignments`. |
| User AI request | `work_requests.input_json.originalRequest`, immutable execution snapshot, and request/Run associations. Not a `discussion_messages` row. |
| Human Discussion | `discussion_messages`: author, Markdown body, references and timestamps. Separate from AI Work history. |
| Executions | `runs`, `workflow_tasks`, task dependencies, `worker_assignments`, attempts and execution events/audit; a request can have multiple Steps and assignments. |
| Worker responses | Assignment `output_json`; completed `workflow_tasks.output_json` stores Conclave StepResult; history API derives final answer from terminal Step. Step text is bounded to 96,000 characters in the runner. |
| Execution metadata | Immutable Workflow/request snapshots, Run policy snapshot, assignment permission/config/input/output/error JSON, identities, model, timeouts, timestamps; StepResult includes Worker/Engine/Profile/tool version and model/effort attribution. |
| Logical session identity | Deterministically derived in Cloud and carried as `sessionKey` with `sessionPolicy`; the dispatcher removes the key from persisted assignment input/config and stores `session_policy` separately. There is no Cloud provider-session registry. |
| Actual CLI session/thread | Engine-owned local JSON mapping under Workspace `Workers/<workerId>/state`; provider CLI owns its native conversation data. Actual provider session IDs do not cross Local Worker Protocol into Cloud. |
| Canonical AI history/context revision | No dedicated canonical Turn log, context revision, summary checkpoint, or per-Worker applied revision. Cloud execution history is durable, but is not automatically replayed as provider-neutral conversation context. |

Schema evidence: [v8 baseline](../../apps/cloud/migrations-v8/0001_conclave_v8.sql),
[Chat schema admission](../../apps/cloud/migrations-v8/0006_chat_workflow_admission.sql),
[local paths](../../apps/workspace/lib/workspace_paths.dart),
[session store](../../engines/cli_worker/lib/src/engine_session_store.dart).
The baseline alone predates Chat's admitted SQL constraints; audit schema with
ordered migrations, not the baseline's Workflow CHECK in isolation.

## Defaults and immutable selections

Model and effort controls update shared persisted Thread bindings, rather than
sending an explicit per-turn selection in the create-request body. Cloud reads and
snapshots those bindings at creation. Later settings changes do not rewrite prior
request snapshots. These are therefore defaults for subsequent requests, but are
currently **Thread-wide shared settings**, not Conversation-scoped preferences
or independent per-user drafts. Settings changes require Work configuration
permission; execution and configuration permissions differ.

Changing the model clears the binding's effort. Worker-specific model catalogs and
model-specific efforts come from Profile metadata projected through inventory.
Default removes explicit overrides; the provider CLI's local configuration supplies
the actual default. Historical metadata may contain null model/effort when omitted;
that is not evidence of the exact model or compute level the CLI ultimately used.

Because settings saves and request submission are separate operations, a future
per-turn contract must explicitly define atomic capture and concurrent editor
semantics. Current snapshots preserve what Cloud read at request creation; they do
not establish an immutable selection captured when the user first typed a draft.

## Existing continuity mechanism

[Cloud session-key derivation](../../apps/cloud/src/work-session-key.ts) hashes:

- Chat: `thread:<id>:chat:conversation`.
- Work: `thread:<id>:direct:work-conversation`.
- Other workflows: `work-request:<requestId>:<stepKind>`.
- Explicit fresh retry: adds `:retry-fresh-<number>` to that base.

Model and effort are absent from the key. Changing either does not intentionally
reset the logical session. Chat and Work remain isolated. Multi-step workflows
pass bounded upstream StepResult text through Conclave prompts; they do not share
the implementer's provider thread with the verifier.

The Engine further partitions its mapping by logical Worker type, Profile
definition, provider tool identity and logical key, inside the local Worker state
root. It records Profile release and session format, resuming only formats declared
compatible by the current Profile. Release number and model are not filename scope
components. An incompatible format returns no prior session, allowing a new native
session. Observed session identity is checked by Engine event interpretation;
resume mismatch is an error. Successful durable execution writes the mapping.

Consequences:

- Switching Workers selects a different local session even with the same Cloud key.
- Switching back can resume that Worker's older thread, missing intervening turns
  executed by another Worker.
- A different Workspace/state root cannot obtain the earlier native thread from
  Cloud. Missing local mapping starts a new session; no canonical-history replay
  currently repairs it.
- A Profile definition/tool identity change partitions continuity; compatible
  releases of the same definition can retain it.
- A fresh retry's derived scope is not persisted as the new base for future normal
  requests: later requests return to the ordinary Thread base.
- Same-session model switching is attempted generically; actual provider support
  requires Profile/provider acceptance evidence, not inference from key stability.

See [Tool Profile session contract](../specifications/TOOL_PROFILE_V1.md) and
[Work retry contract](../specifications/WORK_V1_CONTRACT.md).

## Assumption audit

| Assumption | Finding |
| --- | --- |
| Thread = Worker | False in domain/schema: several bindings can select different Workers. However, simple conversation scopes are implicitly anchored to Thread + binding. |
| Workflow = Worker | False: Workflow Steps own execution semantics; bindings and scheduling independently select logical Workers. |
| Message = execution | False for Discussion. AI timeline currently renders request/result/progress from execution records rather than a canonical Conversation message log. |
| One request = one Worker invocation | False globally: built-ins support dependency graphs, multiple Steps and attempts. Simple Chat/Work currently have one Step, but retries/dispatch recovery must still preserve distinct identities. |
| One visible history = one shared provider context | False: Work history includes requests across Workers/workflows; provider sessions remain partitioned locally. |
| Stateless request = no conversation | False: Chat has stateless mutation coordination and a durable provider session. |
| Model/effort changes redefine previous turns | False for stored snapshots. Next-request settings are shared and mutable before creation. |
| A durable key guarantees complete continuity | False: native state, Profile compatibility, machine placement and missing cross-Worker turns remain material. |

## Boundaries to preserve for later phases

A future Conversation subsystem must distinguish canonical product history and
context revisions from native provider session handles. It must define which turns
belong to each Conversation, how a Worker catches up, how failed/ambiguous turns
are represented, and how multi-step outputs contribute to canonical history.
These are unresolved design decisions, not implemented behavior.

Preserve Workflow graphs, immutable execution attribution, provider-independent
Core, Workspace-owned native state, signed Profile mappings and isolated verifier
sessions. Do not solve continuity by exposing provider credentials/thread IDs to
AX or embedding Codex-specific logic in the Work tab. Independent Conversation
identity, revision fencing, context materialization, switch/reset semantics and
machine recovery need explicit contracts before migration.

## Verification and impact

Phase 0 changes documentation only. No schema, API, runtime behavior, production
state or compatibility migration is changed. Source tracing establishes repository
behavior; fixture tests cannot prove live provider model-switch compatibility or
cross-machine recovery. Targeted test results are recorded in the completion
report accompanying this audit.
